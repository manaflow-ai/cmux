import AppKit
import CmuxNextDesign
@testable import CmuxNextApp
import Foundation
import Testing

/// Three recovery layouts, using the shipped dialog and a public example destination.
/// The balanced layout keeps the cause and all actions in one persistent sheet.
@MainActor @Suite(.serialized) struct SSHRecoveryShotsTests {
    @Test func recoveryVariantsRenderInLightAndDark() throws {
        _ = NSApplication.shared
        let detail = "Could not resolve hostname nohost.invalid: nodename nor servname provided, or not known"
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var shots: [(String, NSImage)] = []
            for variant in ["compact", "balanced", "details"] {
                var spec = SSHConnectRecovery.spec(name: "nohost.invalid", detail: detail)
                if variant == "compact" { spec.lines = ["Could not resolve hostname nohost.invalid."] }
                if variant == "details" { spec.lines = ["nohost.invalid", detail] }
                let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
                let id = center.present(spec, in: .app) { _ in }
                let view = try #require(center.view(id))
                view.appearance = NSAppearance(named: appearance)
                let image = try AddMachineShotsTests.render(view)
                #expect(image.size.width >= 300)
                shots.append(("\(appearance.rawValue) \(variant)", image))
                center.dismiss(id)
            }
            let mode = appearance == .aqua ? "light" : "dark"
            let out = AddServerShotsTests.packageRoot.appending(path: ".build/ssh-recovery-shots-\(mode).png")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AddServerShotsTests.png(AddServerShotsTests.contactSheet(shots)).write(to: out)
            print("ssh-recovery-shots: wrote \(out.path)")
        }
    }
}
