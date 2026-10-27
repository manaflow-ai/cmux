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

    /// The annotations that may leave the Mac: Chromium's process type, product, version, platform and
    /// architecture (components/crash/core/app/crashpad.cc, the handler's process annotations).
    public static let allowedAnnotations: Set<String> = ["ptype", "prod", "ver", "plat", "osarch"]
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
    /// The redacted dump: the bytes that may be sent.
    public let redacted: Data

    /// Chromium's process type (`renderer`, `gpu-process`, `utility`, ...); nil for the browser process.
    public var processType: String? { annotations["ptype"] }

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
