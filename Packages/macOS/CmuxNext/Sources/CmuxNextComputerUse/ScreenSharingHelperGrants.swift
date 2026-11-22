// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextCompat
public import CoreGraphics
public import Darwin
public import Foundation
import os

/// ``GrantHolding`` through the Screen Sharing helper (`<app> Screen Sharing.app` in
/// `Contents/Library`, the bundle `MacScreenHelper` serves screen sharing from): each request is
/// one fresh helper process from its verified copy, responsibility disclaimed
/// (``SignedHelperLaunch``), so macOS checks and names the helper, never this app. The modes are
/// cmux-tui/crates/cmux-rd-host/src/grant_requests.rs: `__post-key CODE FLAGS` and
/// `__screen-still MAX_WIDTH PID FILE`, each one JSON line. The helper is looked up and staged on
/// the first request, never when this value is made.
public nonisolated final class ScreenSharingHelperGrants: GrantHolding {
    /// The helper's executable inside its bundle (`MacScreenHelper.executableName`).
    static let executableName = "cmux-screen-sharing"

    private let lookup: @Sendable () -> URL?
    private let launch: SignedHelperLaunch
    /// The staged executable: nil until the first request, then `.some(nil)` when there is none.
    private let staged = Mutex<URL??>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "screen-sharing-helper-grants")

    public convenience init() {
        self.init(lookup: { ScreenSharingHelperGrants.bundledApp() }, launch: .screenSharing())
    }

    init(lookup: @escaping @Sendable () -> URL?, launch: SignedHelperLaunch) {
        self.lookup = lookup
        self.launch = launch
    }

    /// This build's helper app (`CMUX_NEXT_SCREEN_HELPER_APP` in development), as
    /// `MacScreenHelper.bundled()` finds it; nil when the build carries none. A disk read.
    static func bundledApp(_ bundle: Bundle = .main) -> URL? {
        if let path = ProcessInfo.processInfo.environment["CMUX_NEXT_SCREEN_HELPER_APP"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let library = bundle.bundleURL.appending(path: "Contents/Library", directoryHint: .isDirectory)
        guard let names = try? FileManager.checked.contentsOfDirectory(atPath: library.path),
              let found = names.sorted().first(where: { $0.hasSuffix(" Screen Sharing.app") }) else { return nil }
        let app = library.appending(path: found, directoryHint: .isDirectory)
        guard FileManager.checked.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/\(executableName)").path) else { return nil }
        return app
    }

    /// The helper's one line: whether it held the grant, and a still's size.
    struct Answer: Decodable, Sendable, Equatable {
        var granted: Bool
        var width: Int?
        var height: Int?
    }

    /// `request-permission`'s line: the helper's grants after macOS's prompt (still off until the
    /// person answers it).
    struct Permissions: Decodable, Sendable {
        var screenRecording: Bool
        var accessibility: Bool

        enum CodingKeys: String, CodingKey {
            case screenRecording = "screen_recording"
            case accessibility
        }
    }

    @concurrent private func executable() async -> URL? {
        if let known = staged.withLock({ $0 }) { return known }
        var url: URL?
        if let app = lookup() {
            if let copy = await launch.stage(app) {
                url = copy.appending(path: "Contents/MacOS/\(Self.executableName)")
            } else {
                logger.error("the Screen Sharing helper could not be copied out of the app: \(app.path, privacy: .public)")
            }
        }
        staged.withLock { $0 = .some(url) }
        return url
    }

    @concurrent private func ask<Reply: Decodable & Sendable>(_ arguments: [String], as _: Reply.Type) async -> Reply? {
        guard let executable = await executable() else { return nil }
        switch await SignedHelperLaunch.answer(executable: executable, arguments: arguments, as: Reply.self) {
        case let .success(answer): return answer
        case let .failure(failure):
            logger.error("the Screen Sharing helper gave no answer to \(arguments.first ?? "", privacy: .public): \(String(describing: failure), privacy: .public)")
            return nil
        }
    }

    @concurrent public func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) async -> GrantHolderAnswer {
        Self.result(await ask(Self.postKeyArguments(keyCode, flags: flags), as: Answer.self))
    }

    @concurrent public func screenStill(maxWidth: Int, excluding pid: pid_t) async -> GrantHolderStill {
        guard await executable() != nil else { return .unavailable }
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-screen-still-\(UUID().uuidString)", directoryHint: .isDirectory)
        do { try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) } catch {
            return .unavailable
        }
        defer { try? FileManager.checked.removeItem(at: folder) }
        let file = folder.appending(path: "still.rgba", directoryHint: .notDirectory)
        let answer = await ask(["__screen-still", String(maxWidth), String(pid), file.path], as: Answer.self)
        switch Self.result(answer) {
        case .notGranted: return .notGranted
        case .unavailable: return .unavailable
        case .done: break
        }
        guard let width = answer?.width, let height = answer?.height, let data = try? Data(blockingContentsOf: file) else {
            return .unavailable
        }
        let pixels = GrantHolderPixels(width: width, height: height, rgba: data)
        return pixels.image == nil ? .unavailable : .pixels(pixels)
    }

    @concurrent public func requestAccessibility() async {
        _ = await ask(["request-permission", "accessibility"], as: Permissions.self)
    }

    @concurrent public func requestScreenRecording() async {
        _ = await ask(["request-permission", "screen-recording"], as: Permissions.self)
    }

    /// `__post-key CODE FLAGS`, the flags cut to the four modifiers the helper accepts.
    static func postKeyArguments(_ keyCode: CGKeyCode, flags: CGEventFlags) -> [String] {
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        return ["__post-key", String(keyCode), String(modifiers.rawValue)]
    }

    static func result(_ answer: Answer?) -> GrantHolderAnswer {
        guard let answer else { return .unavailable }
        return answer.granted ? .done : .notGranted
    }
}
