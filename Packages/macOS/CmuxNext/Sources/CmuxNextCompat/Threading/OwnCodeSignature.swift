import Foundation
import Security

/// This process's own code signature: its Developer ID team and its signing identifier.
///
/// A running process's signature does not change, so it is read once per process, through the checked
/// Security seams (three calls that wait for the kernel and the code signing daemon). The app reads it on
/// its system lane at launch, before the first main-thread reader (the daemon prestart, CloudService, the
/// acpmux and Computer Use admission rules), which then finds it read: the main thread never makes the
/// calls (Chrome's UI-thread rule, base/threading/thread_restrictions.h).
public struct OwnCodeSignature: Sendable, Equatable {
    /// The team of the signing certificate; nil for an ad-hoc or unsigned build.
    public let teamIdentifier: String?
    /// The signing identifier (the bundle id for an app); nil when the signature has none.
    public let identifier: String?

    /// A signature with these facts (tests).
    public init(teamIdentifier: String?, identifier: String?) {
        self.teamIdentifier = teamIdentifier
        self.identifier = identifier
    }

    /// This process's signature, read once. The first read blocks: the app makes it on its system lane at launch.
    public static var current: OwnCodeSignature { process }

    private static let process = OwnCodeSignature.read()

    /// Reads this process's signature now (a blocking call: run it off the main thread).
    public static func read(fileID: StaticString = #fileID, line: UInt = #line) -> OwnCodeSignature {
        var code: SecCode?
        guard blockingSecCodeCopySelf([], &code, fileID: fileID, line: line) == errSecSuccess, let code else { return .unsigned }
        var staticCode: SecStaticCode?
        guard blockingSecCodeCopyStaticCode(code, [], &staticCode, fileID: fileID, line: line) == errSecSuccess,
              let staticCode else { return .unsigned }
        var information: CFDictionary?
        guard blockingSecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information,
                                                    fileID: fileID, line: line) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return .unsigned }
        let nonEmpty = { (key: CFString) in (dictionary[key as String] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return OwnCodeSignature(teamIdentifier: nonEmpty(kSecCodeInfoTeamIdentifier), identifier: nonEmpty(kSecCodeInfoIdentifier))
    }

    private static let unsigned = OwnCodeSignature(teamIdentifier: nil, identifier: nil)
}
