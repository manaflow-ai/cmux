import CmuxNextCompat
import CmuxNextTrace
import Darwin
public import Foundation

/// The system profile a metrics file carries in its header: which build on which system recorded the samples
/// (plans/cmux-next/chrome-parity/p09-observability.md section 3D). An upload sends each launch's samples with
/// its own profile, so a crashed launch's numbers are filed under the version that recorded them, not the next
/// launch's. Chrome embeds a `SystemProfileProto` in each persistent histogram file for the same reason
/// (components/metrics/persistent_system_profile.h).
///
/// ```swift
/// let profile = MetricsProfile.current(channel: "nightly", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
/// ```
public struct MetricsProfile: Sendable, Equatable {
    /// The app's marketing version (`CFBundleShortVersionString`).
    public var appVersion: String
    /// The build number (`CFBundleVersion`).
    public var buildNumber: String
    /// The release channel (`stable`, `nightly`, `dev`).
    public var channel: String
    /// The macOS version, `major.minor.patch`.
    public var osVersion: String
    /// The hardware class: the `hw.model` identifier (`Mac15,3`), Chrome's hardware class on macOS.
    public var hardwareClass: String
    /// `kern.bootsessionuuid` as 16 bytes, empty when unknown: a launch whose run ended in another boot session
    /// ended with the system, not with a crash (task 053).
    public var bootSessionUUID: [UInt8]
    /// The main executable's `LC_UUID`, empty when it has none.
    public var buildUUID: [UInt8]
    /// The day the build was made; it decides which histograms have expired (``HistogramID/Expiry``).
    public var buildDay: Day

    /// A profile from its fields. Each text field keeps at most ``textBytes`` UTF-8 bytes in a file.
    public init(appVersion: String, buildNumber: String, channel: String, osVersion: String, hardwareClass: String,
                bootSessionUUID: [UInt8] = [], buildUUID: [UInt8] = [], buildDay: Day) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.channel = channel
        self.osVersion = osVersion
        self.hardwareClass = hardwareClass
        self.bootSessionUUID = bootSessionUUID
        self.buildUUID = buildUUID
        self.buildDay = buildDay
    }

    /// The calling process's profile: the version and build of `bundle`, the OS version, `hw.model`, the boot
    /// session and the executable's UUID. Two `sysctl` calls and a walk of the loaded image, no file.
    ///
    /// - Parameters:
    ///   - bundle: The app bundle whose Info.plist names the version.
    ///   - channel: The release channel.
    ///   - buildDay: The day the build was made (the owner knows it from the build; tests pass their own).
    public static func current(bundle: Bundle = .main, channel: String, buildDay: Day) -> MetricsProfile {
        let info = bundle.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let facts = TraceBlackBox.ProcessFacts.current()
        return MetricsProfile(appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
                              buildNumber: info["CFBundleVersion"] as? String ?? "0", channel: channel,
                              osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                              hardwareClass: hardwareModel(), bootSessionUUID: facts.bootSessionUUID,
                              buildUUID: facts.buildUUID, buildDay: buildDay)
    }

    /// `hw.model`, empty when the kernel does not answer.
    private static func hardwareModel() -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = buffer.count
        guard blockingCall(.systemCall, { sysctlbyname("hw.model", &buffer, &length, nil, 0) }) == 0 else { return "" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension MetricsProfile {
    /// A calendar day, as a build's date and an expiry are written.
    public struct Day: Sendable, Hashable, Comparable {
        /// The year (2026).
        public var year: Int
        /// The month, 1 to 12.
        public var month: Int
        /// The day of the month, 1 to 31.
        public var day: Int

        /// A day from its parts.
        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        /// The day as the header's u32 `yyyymmdd`.
        var packed: UInt32 { UInt32(clamping: year * 10_000 + month * 100 + day) }

        /// The day of a header's `yyyymmdd`.
        init(packed: UInt32) {
            self.init(year: Int(packed / 10_000), month: Int(packed / 100 % 100), day: Int(packed % 100))
        }

        public static func < (lhs: Day, rhs: Day) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }
    }

    /// The UTF-8 bytes a text field keeps in a file (a 64-byte slot, NUL padded, at least one NUL).
    public static let textBytes = 63

    /// The header offsets of the profile (``MetricsStore`` "File layout").
    enum Offsets {
        static let bootSessionUUID = 64
        static let buildUUID = 80
        static let buildDay = 96
        static let appVersion = 104
        static let buildNumber = 168
        static let channel = 232
        static let osVersion = 296
        static let hardwareClass = 360
        /// The end of the profile.
        static let end = 424
    }

    /// Writes the profile into a header at `header` (its bytes there are zero).
    func write(into header: UnsafeMutableRawPointer) {
        Self.writeBytes(bootSessionUUID.prefix(16), at: header + Offsets.bootSessionUUID)
        Self.writeBytes(buildUUID.prefix(16), at: header + Offsets.buildUUID)
        header.storeBytes(of: buildDay.packed.littleEndian, toByteOffset: Offsets.buildDay, as: UInt32.self)
        for (text, offset) in [(appVersion, Offsets.appVersion), (buildNumber, Offsets.buildNumber), (channel, Offsets.channel),
                               (osVersion, Offsets.osVersion), (hardwareClass, Offsets.hardwareClass)] {
            Self.writeBytes(Self.truncated(text), at: header + offset)
        }
    }

    /// The profile a header at `header` holds.
    init(reading header: UnsafeRawPointer) {
        func text(_ offset: Int) -> String {
            let bytes = UnsafeRawBufferPointer(start: header + offset, count: Self.textBytes)
            return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        func uuid(_ offset: Int) -> [UInt8] {
            let bytes = Array(UnsafeRawBufferPointer(start: header + offset, count: 16))
            return bytes.allSatisfy { $0 == 0 } ? [] : bytes
        }
        self.init(appVersion: text(Offsets.appVersion), buildNumber: text(Offsets.buildNumber), channel: text(Offsets.channel),
                  osVersion: text(Offsets.osVersion), hardwareClass: text(Offsets.hardwareClass),
                  bootSessionUUID: uuid(Offsets.bootSessionUUID), buildUUID: uuid(Offsets.buildUUID),
                  buildDay: Day(packed: UInt32(littleEndian: header.loadUnaligned(fromByteOffset: Offsets.buildDay, as: UInt32.self))))
    }

    /// `text`'s UTF-8 bytes, cut to ``textBytes`` at a character boundary.
    static func truncated(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for character in text {
            guard bytes.count + character.utf8.count <= textBytes else { break }
            bytes += character.utf8
        }
        return bytes
    }

    private static func writeBytes(_ bytes: some Collection<UInt8>, at address: UnsafeMutableRawPointer) {
        for (index, byte) in bytes.enumerated() {
            address.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
        }
    }
}
