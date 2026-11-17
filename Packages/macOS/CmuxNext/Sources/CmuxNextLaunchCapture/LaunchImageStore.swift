import CmuxNextControl
import Foundation
import os
#if canImport(CCmuxLaunchImageFFI)
import CCmuxLaunchImageFFI
#endif

// The launch images' C ABI (cmux-tui/crates/cmux-launch-image, `include/cmux_launch_image.h`): each window's
// last frame on disk, its capture schedule, and the age rule of a page region. Rust owns the decisions;
// this file only crosses the boundary.
//
// Step B: the module `CCmuxLaunchImageFFI` reaches the app with the CCmuxAppFFI release that has
// cmux-launch-image (#44472, #45084 and this PR's ABI 3), once app-ffi is re-pinned
// (docs/ci/app-ffi-release.md). Until then `canImport` is false, every schedule is never due, and nothing
// is captured: the rest of the capture compiles and is checked against the pinned FFI. Remove the `#if`
// with that re-pin.

/// Milliseconds of one monotonic clock (`ContinuousClock`, so time asleep counts), from an origin a year
/// before the first use: every instant of this process is a positive count. The schedule's events and a
/// capture's region ages all read it.
nonisolated struct LaunchCaptureClock: Sendable {
    private static let origin = ContinuousClock.now - .seconds(365 * 24 * 3600)

    static func milliseconds(_ instant: ContinuousClock.Instant) -> UInt64 {
        let (seconds, attoseconds) = origin.duration(to: instant).components
        guard seconds >= 0 else { return 0 }
        return UInt64(seconds) &* 1000 &+ UInt64(attoseconds / 1_000_000_000_000_000)
    }

    static func now() -> UInt64 { milliseconds(.now) }
}

/// One window's capture schedule (cmux-launch-image `schedule`): fed the window's events on the main actor,
/// asked when to capture. Its epoch check also runs in a publish's hand-off, off the main actor: one lock
/// covers every call, held for the Rust call only (and, in ``whileCurrent(_:_:)``, for the record's
/// dictionary write), never across I/O.
nonisolated final class LaunchImageSchedule: Sendable {
    /// The window events, as the C ABI numbers them.
    nonisolated enum Event: UInt32 {
        case changed = 1, hidden = 2, shown = 3, transitionBegan = 4, transitionEnded = 5, captureFailed = 6, captureDone = 7
    }

    #if canImport(CCmuxLaunchImageFFI)
    /// The Rust schedule, read only under its lock; freed in deinit.
    private let schedule = OSAllocatedUnfairLock<OpaquePointer?>(uncheckedState: cmux_launch_image_schedule_new(0))

    init() {}
    deinit { schedule.withLockUnchecked { cmux_launch_image_schedule_free($0) } }

    /// Records `event` now; returns when a capture is due (``LaunchCaptureClock`` ms), or nil.
    func note(_ event: Event, at now: UInt64) -> UInt64? {
        let due = schedule.withLockUnchecked { cmux_launch_image_schedule_note($0, event.rawValue, now) }
        return due < 0 ? nil : UInt64(due)
    }

    /// True when a capture is due at `now`: capture now (the change counts as taken).
    func takeDue(at now: UInt64) -> Bool { schedule.withLockUnchecked { cmux_launch_image_schedule_take_due($0, now) } }

    /// True when the quit should capture this window (shown, settled, changed or never captured).
    func takeQuit() -> Bool { schedule.withLockUnchecked { cmux_launch_image_schedule_take_quit($0) } }

    /// The change epoch a capture starts at.
    var epoch: UInt64 { schedule.withLockUnchecked { cmux_launch_image_schedule_epoch($0) } }

    /// Runs `body` while nothing happened to the window since `epoch` (no change, hide, show or transition)
    /// and it is capturable, with the schedule held, so no event lands between the check and `body` (review
    /// F2 of #44472). False, and `body` not run, when the capture is stale.
    func whileCurrent(_ epoch: UInt64, _ body: () -> Void) -> Bool {
        schedule.withLockUnchecked { schedule in
            guard cmux_launch_image_schedule_is_current(schedule, epoch) else { return false }
            body()
            return true
        }
    }
    #else
    init() {}
    func note(_ event: Event, at now: UInt64) -> UInt64? { nil }
    func takeDue(at now: UInt64) -> Bool { false }
    func takeQuit() -> Bool { false }
    var epoch: UInt64 { 0 }
    func whileCurrent(_ epoch: UInt64, _ body: () -> Void) -> Bool { false }
    #endif
}

/// The windows' launch images folder (`<Application Support>/<bundle id>/launch-images`, 0700, files 0600;
/// the stage-0 window reads `<window key>.<generation>.png` there). Every call does file I/O: off the main
/// actor only (`BackgroundWork`'s files lane).
nonisolated struct LaunchImageStore: Sendable {
    static let directoryName = "launch-images"
    let directory: URL
    /// The bundle's `CFBundleVersion` and `CMUXCommit`: the build part of each image's record key, so the
    /// next launch of another build never draws this one's image.
    let version: String?, commit: String?

    init(bundleID: String, info: [String: Any]) {
        self.init(directory: LaunchTimesFile.supportDirectory(bundleID: bundleID)
            .appending(path: Self.directoryName, directoryHint: .isDirectory), info: info)
    }

    init(directory: URL, info: [String: Any]) {
        self.directory = directory
        version = info["CFBundleVersion"] as? String; commit = info["CMUXCommit"] as? String
    }

    /// Writes `png` as `windowID`'s newest image and calls `handOff` with it before any older image of the
    /// folder is removed (publishes take turns until it returns): the launch record names the image's key
    /// there (`<build>/<window key>/<generation>`, record v2 `image_key`), never its path.
    /// Nil when nothing was written (the window keeps its previous image).
    func publish(windowID: String, png: Data, handOff: (LaunchRecordImage) -> Void) -> LaunchRecordImage? {
        #if canImport(CCmuxLaunchImageFFI)
        return withoutActuallyEscaping(handOff) { handOff in
            let context = HandOff { image in
                if let image = record(image, windowID: windowID) { handOff(image) }
            }
            var out = CmuxLaunchImage()
            let written = withExtendedLifetime(context) {
                directory.path.withCString { dir in
                    windowID.withCString { id in
                        png.withUnsafeBytes { bytes in
                            cmux_launch_image_publish_with(dir, id, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &out, { image, context in
                                guard let image, let context else { return }
                                Unmanaged<HandOff>.fromOpaque(context).takeUnretainedValue().body(image.pointee)
                            }, Unmanaged.passUnretained(context).toOpaque())
                        }
                    }
                }
            }
            return written ? record(out, windowID: windowID) : nil
        }
        #else
        return nil
        #endif
    }

    /// Removes every image of `windowID` (the window closed).
    func removeWindow(_ windowID: String) {
        #if canImport(CCmuxLaunchImageFFI)
        _ = directory.path.withCString { dir in windowID.withCString { cmux_launch_image_remove_window(dir, $0) } }
        #endif
    }

    /// Keeps only the `live` windows' images (each file once older than the store's grace).
    func prune(live: [String]) {
        #if canImport(CCmuxLaunchImageFFI)
        let strings = live.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard !strings.contains(where: { $0 == nil }) else { return }
        let pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } }
        _ = directory.path.withCString { dir in
            pointers.withUnsafeBufferPointer { cmux_launch_image_prune(dir, $0.baseAddress, $0.count, UInt64(CMUX_LAUNCH_IMAGE_PRUNE_GRACE_MS)) }
        }
        #endif
    }

    #if canImport(CCmuxLaunchImageFFI)
    /// The hand-off closure, passed through the C call's context pointer for the call only.
    private nonisolated final class HandOff {
        let body: (CmuxLaunchImage) -> Void
        init(_ body: @escaping (CmuxLaunchImage) -> Void) { self.body = body }
    }

    /// The record's view of `windowID`'s published image: its key (Rust's `cmux_launch_image_record_key`)
    /// and pixel size; nil when the key cannot be made.
    func record(_ image: CmuxLaunchImage, windowID: String) -> LaunchRecordImage? {
        var key = [CChar](repeating: 0, count: Int(CMUX_LAUNCH_IMAGE_KEY_CAPACITY))
        let made = version.withOptionalCString { version in
            commit.withOptionalCString { commit in
                windowID.withCString { id in cmux_launch_image_record_key(version, commit, id, image.generation, &key, key.count) }
            }
        }
        guard made else { return nil }
        return LaunchRecordImage(key: String(decoding: key.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                                 pixelWidth: image.pixel_width, pixelHeight: image.pixel_height)
    }
    #endif
}

/// One Chromium page region of a window at capture time (cmux-launch-image `region`): whether the page's
/// cached image still shows it. Times are ``LaunchCaptureClock`` ms; versions the page's picture version.
nonisolated struct LaunchPageRegion: Sendable {
    var imageTakenAt: UInt64?
    var imageVersion: Int?
    var pageVersion: Int
    var pageChangedAt: UInt64?
    var compositeAt: UInt64

    /// True when the cached image is painted; false: the region is plain (the theme's fill, no stale text).
    /// The rule is Rust's (`cmux_launch_image_page_region`); without that ABI nothing is painted.
    var paintsImage: Bool {
        #if canImport(CCmuxLaunchImageFFI)
        var region = CmuxLaunchImagePageRegion(
            has_image: imageTakenAt != nil, image_taken_ms: imageTakenAt ?? 0,
            has_image_version: imageVersion != nil, image_version: UInt64(bitPattern: Int64(imageVersion ?? 0)),
            page_version: UInt64(bitPattern: Int64(pageVersion)),
            has_page_changed: pageChangedAt != nil, page_changed_ms: pageChangedAt ?? 0, composite_ms: compositeAt)
        return cmux_launch_image_page_region(&region) == UInt8(CMUX_LAUNCH_IMAGE_REGION_IMAGE)
        #else
        return false
        #endif
    }
}

private extension Optional where Wrapped == String {
    /// `body` with the string's C form, or null for nil.
    nonisolated func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let string): string.withCString { body($0) }
        case .none: body(nil)
        }
    }
}
