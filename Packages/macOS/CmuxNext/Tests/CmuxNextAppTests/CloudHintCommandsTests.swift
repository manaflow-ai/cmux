import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Every Cloud failure that names a next command names one the CLI offers:
/// `cmux cloud <verb>` is a CLI-offered action (not a guiOnly or clipboard
/// exemption, which prints `not_a_verb`), and each `--flag` it passes is an
/// argument of the action the message belongs to.
@MainActor
struct CloudHintCommandsTests {
    /// The rewritten hints (audit group A1) with the action each one answers.
    static var hints: [(text: String, action: String?)] {
        [
            (CloudStrings.signInFirst, nil), (CloudStrings.noMachine, nil), (CloudStrings.notConnected, nil),
            (CloudStrings.alreadySignedIn, "palette.auth.signIn"), (CloudStrings.noAddress, "cloudCopyPort"),
            (CloudStrings.commandRequired, "cloudExec"), (CloudStrings.fileContentsRequired, "cloudFileWrite"),
            (CloudStrings.publicKeyRequired, "cloudPrepareSCP"), (CloudStrings.tunnelKeyRequired, "cloudTunnelRotateKey"), (CloudStrings.snapshotRequired, "palette.cloud.restore"),
            (CloudStrings.snapshotRequired, "palette.cloud.deleteSnapshot"),
            (CloudMoveStrings.moveFailed("x"), nil), (CloudBringBackStrings.failed("x"), nil),
            (CloudStrings.gitHubMissing, nil), (CloudStrings.gitHubFailed, nil),
        ]
    }

    static func verbs(in text: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "cmux cloud ([a-z-]+)")
        let range = NSRange(text.startIndex..., in: text)
        return (pattern?.matches(in: text, range: range) ?? []).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    static func flags(in text: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "--([a-z][a-z-]*)")
        let range = NSRange(text.startIndex..., in: text)
        return (pattern?.matches(in: text, range: range) ?? []).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    /// `--public-key` names the argument `publicKey` (cmux-tui `argument_name`).
    static func argumentName(_ flag: String) -> String {
        let parts = flag.split(separator: "-")
        return parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    }

    @Test func everyNamedVerbIsOfferedOnTheCLI() {
        for hint in Self.hints {
            for verb in Self.verbs(in: hint.text) {
                let descriptor = ActionCatalog.all.first { $0.cliName == "cloud \(verb)" }
                #expect(descriptor?.cli == true, "`cmux cloud \(verb)` in “\(hint.text)” is not a CLI verb")
            }
        }
        #expect(Self.verbs(in: CloudStrings.notConnected) == ["resume-machine"])
        #expect(!CloudStrings.tunnelKeyRequired.contains("ssh"), "a tunnel key is a WireGuard key")
    }

    @Test func everyNamedFlagIsAnArgumentOfItsAction() throws {
        for hint in Self.hints {
            guard let id = hint.action else { continue }
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id }, "\(id)")
            for flag in Self.flags(in: hint.text) where flag != "target" {
                #expect(descriptor.arguments.contains { $0.name == Self.argumentName(flag) }, "--\(flag) in “\(hint.text)” is not an argument of \(id)")
            }
        }
    }

    /// A verb that acts on one machine names it: `--target machine:<id>`
    /// follows it, or the suggested command answers "No Cloud machine is selected".
    @Test func aMachineVerbNamesItsTarget() {
        for hint in Self.hints {
            for verb in Self.verbs(in: hint.text) {
                guard let descriptor = ActionCatalog.all.first(where: { $0.cliName == "cloud \(verb)" }),
                      descriptor.targets.contains(.machine) else { continue }
                #expect(hint.text.contains("cmux cloud \(verb) --target machine:"), "`cmux cloud \(verb)` in “\(hint.text)” names no machine")
            }
        }
    }

    /// The reason goes last, so a reason that ends with a full stop never doubles it.
    @Test func theReasonOfAFailedMoveOrStartComesLast() {
        #expect(CloudMoveStrings.moveFailed("REASON.").hasSuffix("REASON."))
        #expect(CloudBringBackStrings.failed("REASON.").hasSuffix("REASON."))
        #expect(CloudStrings.progressFailed("REASON.").hasSuffix("REASON."))
    }

    /// An upload refusal names the limits the app enforces, from the same constants.
    @Test func anUploadRefusalNamesTheLimits() {
        let size = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) }
        #expect(CloudUploadStrings.refused.contains(size(CloudUploads.maximumFileBytes)), "\(CloudUploadStrings.refused)")
        #expect(CloudUploadStrings.refused.contains(size(CloudUploads.maximumTotalBytes)), "\(CloudUploadStrings.refused)")
    }
}
