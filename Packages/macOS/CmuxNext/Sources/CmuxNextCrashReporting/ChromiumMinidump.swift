public import Foundation

/// A Crashpad minidump of a Chromium process (p09-observability-105), read and redacted so that it can leave the
/// Mac: the minidump format (Crashpad's compat/non_win/dbghelp.h) plus Crashpad's own stream
/// (third_party/crashpad/crashpad/minidump/minidump_extensions.h).
///
/// Redaction keeps bytes by allowlist. It keeps the header, the stream directory, and these streams with what they
/// reference: threads (register contexts only), modules (names cut to file names, PDB 7.0 CodeView records), the
/// exception, system and misc info, the memory region list (addresses and protections only), thread names, and
/// Crashpad's info with only the ``allowedAnnotations`` whose values are plain words. Every other byte becomes
/// zero: stack and heap memory, every other stream (the macOS `__crash_info` messages among them), list
/// annotations, Crashpad's install-wide client id, and anything nothing references. Stack memory stays out until
/// Lawrence decides otherwise (p09-observability.md, risk 6), so Sentry gets the top frame of each thread.
public nonisolated struct ChromiumMinidump: Sendable, Equatable {
    /// Why a file is not a minidump this type can read.
    public enum Failure: Error, Equatable, Sendable {
        /// No `MDMP` signature.
        case notMinidump
        /// A structure or a reference goes past the end of the file.
        case truncated(offset: Int)
    }

    /// One loaded image: what Sentry needs to symbolicate an address in it.
    public struct Module: Sendable, Equatable {
        /// The file name (no folder).
        public let name: String
        public let base: UInt64
        public let size: UInt32
        /// The Mach-O UUID (Sentry's debug id), nil without a PDB 7.0 CodeView record.
        public let debugID: String?
    }

    /// The cmux build a dump's process belonged to, from its `ver` annotation, which
    /// `scripts/cmux-next/write-crash-reporter-cfg.sh` sets to `<version>+<build> cef<chromium>-<api>`.
    public struct CrashedBuild: Sendable, Equatable {
        public let version: String
        public let build: String
        /// `<chromium>-<api>`, when the annotation names it.
        public let chromium: String?

        /// Nil for a `ver` in another form (a dump from a build before the cmux version was recorded).
        init?(ver: String) {
            let parts = ver.split(separator: " ", maxSplits: 1).map(String.init)
            let release = parts.first?.split(separator: "+", maxSplits: 1).map(String.init) ?? []
            guard release.count == 2, !release[0].isEmpty, !release[1].isEmpty else { return nil }
            version = release[0]
            build = release[1]
            chromium = parts.count == 2 && parts[1].hasPrefix("cef") ? String(parts[1].dropFirst(3)) : nil
        }
    }

    /// The annotations that may leave the Mac: Chromium's process type, product, version (the cmux build), platform
    /// and architecture (components/crash/core/app/crashpad.cc, the handler's process annotations).
    public static let allowedAnnotations: Set<String> = ["ptype", "prod", "ver", "plat", "osarch"]
    /// Crashpad's exception code for a dump written without a crash (`DumpWithoutCrashing`, `CRASHPAD_SIMULATE_CRASH`):
    /// `kMachExceptionSimulated` (crashpad/util/mach/exception_types.h), "CPsx".
    public static let simulatedExceptionCode: UInt32 = 0x4350_7378
    /// The longest annotation value kept.
    static let maxAnnotationValueBytes = 64

    /// The crashed process's id (the misc info stream), when the dump has it.
    public let processID: Int32?
    /// When Crashpad wrote the dump (the header's time stamp).
    public let writtenAt: Date
    /// The file name of the first module, the process's main executable.
    public let mainModule: String?
    /// The annotations kept, by name.
    public let annotations: [String: String]
    /// The exception stream's code: the Mach exception, or ``simulatedExceptionCode``; nil without the stream.
    public let exceptionCode: UInt32?
    /// The crashing thread's program counter and link register (arm64), pointer authentication bits removed.
    public let crashPC: UInt64?
    public let crashLR: UInt64?
    /// The loaded images, the main executable first.
    public let modules: [Module]
    /// The redacted dump: the bytes that may be sent.
    public let redacted: Data

    /// Chromium's process type (`renderer`, `gpu-process`, `utility`, ...); nil for the browser process.
    public var processType: String? { annotations["ptype"] }

    /// Whether the process wrote the dump without crashing (it may still run): a report, not a crash.
    public var isSimulated: Bool { exceptionCode == Self.simulatedExceptionCode }

    /// The cmux build that wrote the dump, when its `ver` annotation names one.
    public var crashedBuild: CrashedBuild? { annotations["ver"].flatMap(CrashedBuild.init(ver:)) }

    /// Reads and redacts a dump.
    /// - Parameters:
    ///   - data: The minidump file's bytes.
    ///   - allowedAnnotations: The annotation names that may stay.
    public init(data: Data, allowedAnnotations: Set<String> = ChromiumMinidump.allowedAnnotations) throws(Failure) {
        var redactor = try MinidumpRedactor(bytes: [UInt8](data), allowed: allowedAnnotations)
        try redactor.redact()
        processID = redactor.processID
        writtenAt = Date(timeIntervalSince1970: TimeInterval(redactor.timeStamp))
        mainModule = redactor.mainModule
        annotations = redactor.annotations
        exceptionCode = redactor.exceptionCode
        let mask = redactor.addressMask
        crashPC = redactor.crashPC.map { mask == 0 ? $0 : $0 & mask }
        crashLR = redactor.crashLR.map { mask == 0 ? $0 : $0 & mask }
        modules = redactor.modules
        redacted = Data(redactor.output())
    }

    /// The last path component of a module path (`/Users/USER/.../cmux Helper` gives `cmux Helper`).
    static func fileName(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }

    /// Whether an allowlisted annotation's value is plain enough to send: at most 64 bytes of ASCII letters,
    /// digits, spaces and `._-+(),`. No `/` or `:`, so no URL or path fits.
    static func isPlainValue(_ value: String) -> Bool {
        value.utf8.count <= maxAnnotationValueBytes && value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"): true
            case UInt8(ascii: " "), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "+"),
                 UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: ","): true
            default: false
            }
        }
    }
}
