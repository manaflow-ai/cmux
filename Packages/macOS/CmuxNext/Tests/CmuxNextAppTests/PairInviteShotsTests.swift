import AppKit
@testable import CmuxNextServer
import Foundation
import Testing

/// Renders every state of the Pair Another Machine card (the code with its QR and lines, a machine
/// arriving, its facts and words with Confirm, paired, voided, expired, lost, signed out) into one
/// contact sheet, over the mock invite and the mock server's preview, so a fleet run returns the
/// card's look as an artifact: `Packages/macOS/CmuxNext/.build/pair-invite-shots.png`. It also
/// checks that every state draws something at a sane size, with no SwiftUI host. The data is fake
/// only (code ABCDE-12345, the machine `build-box`, no account), so the sheet may go in a public PR.
@MainActor @Suite(.serialized) struct PairInviteShotsTests {
    enum Shot: String, CaseIterable {
        case showing = "1 the code"
        case copied = "2 line copied"
        case lookingUp = "3 a machine arrived"
        case review = "4 confirm its words"
        case paired = "5 paired"
        case voided = "6 a second machine"
        case expired = "7 expired"
        case lost = "8 connection lost"
        case signedOut = "9 signed out"

        func drive(_ fake: PairInviteFlowTests.Fake, _ source: MockServerSource) async -> PairInviteModel {
            if self == .signedOut { fake.mintResult = .failure(.signedOut) }
            if self == .lookingUp { source.echoImmediately = false }
            let model = fake.model(source)
            await model.mint()
            switch self {
            case .showing, .signedOut: break
            case .copied: model.perform(.copyLine)
            case .lookingUp, .review: fake.push(.arrived(code: MockServerScenario.offerCode))
            case .paired:
                fake.push(.arrived(code: MockServerScenario.offerCode))
                await Self.settle()
                model.confirm()
            case .voided: fake.push(.voided(reason: "second_redemption"))
            case .expired:
                fake.now = fake.invite.expiresAt
                model.tick()
            case .lost: fake.socket?.finish()
            }
            await Self.settle()
            return model
        }

        static func settle() async {
            for _ in 0..<100 { await Task.yield() }
        }
    }

    /// The arriving machine's name in every shot.
    static let machineName = "build-box"

    /// Whether some label or field under `view` shows `text`.
    static func showsText(_ view: NSView, _ text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue.contains(text) { return true }
        if let scroll = view as? NSScrollView, let doc = scroll.documentView, showsText(doc, text) { return true }
        return view.subviews.contains { showsText($0, text) }
    }

    @Test func everyStateRendersToTheContactSheet() async throws {
        _ = NSApplication.shared
        var shots: [(String, NSImage)] = []
        for shot in Shot.allCases {
            let fake = PairInviteFlowTests.Fake()
            let source = MockServerSource()
            source.candidate.name = Self.machineName
            let model = await shot.drive(fake, source)
            let view = PairInviteView(model: model)
            #expect(!AddDeviceShotsTests.hostsSwiftUI(view), "\(shot) hosts SwiftUI")
            let image = try AddMachineShotsTests.render(view)
            #expect(image.size.width >= 400, "\(shot) is \(image.size.width) pt wide")
            #expect(image.size.height >= 120, "\(shot) is \(image.size.height) pt tall")
            shots.append((shot.rawValue, image))
            if shot == .showing {
                for id in ["cmux.pairInvite.code", "cmux.pairInvite.qr", "cmux.pairInvite.line", "cmux.pairInvite.installLine",
                           "cmux.pairInvite.countdown", "cmux.pairInvite.button.copyCode", "cmux.pairInvite.button.line"] {
                    #expect(AddDeviceShotsTests.find(view, id: id) != nil, "the code card shows \(id)")
                }
            }
            if shot == .review || shot == .paired {
                #expect(Self.showsText(view, Self.machineName), "\(shot) names \(Self.machineName)")
            }
            if shot == .review {
                for id in ["cmux.pairInvite.facts", "cmux.pairInvite.words", "cmux.pairInvite.name", "cmux.pairInvite.button.confirm"] {
                    #expect(AddDeviceShotsTests.find(view, id: id) != nil, "the arrived card shows \(id)")
                }
            }
            model.close()
        }
        let sheet = AddServerShotsTests.contactSheet(shots)
        let out = AddServerShotsTests.packageRoot.appending(path: ".build/pair-invite-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AddServerShotsTests.png(sheet).write(to: out)
        print("pair-invite-shots: wrote \(out.path)")
    }
}
