#if os(iOS)
import CmuxMobileDesign
@testable import CmuxMobileShell
import SwiftUI
import Testing
import UIKit

/// How much of the terminal each chip placement covers, in pt², on the gallery's terminal page
/// (the same `TerminalChipPage` the shots draw): the chip's own area and the part of it over
/// output lines. Records `chip-coverage.txt` for the PR's table.
@MainActor @Suite(.serialized) struct TerminalChipCoverageTests {
    @MainActor final class Frames {
        var chip: CGRect?
        var lines: [Int: CGRect] = [:]
    }

    func measure(_ variant: TerminalChipPage.Variant, _ state: ConnectionChip.Content) async -> Frames {
        let frames = Frames()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874) // iPhone 17 Pro
        let host = UIHostingController(rootView: AnyView(
            TerminalChipPage(variant: variant, state: state,
                             onChipFrame: { frames.chip = $0 },
                             onLineFrame: { frames.lines[$0] = $1 })
                .padding(16) // the gallery's page inset
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(16)) // test: one display frame of layout
            host.view.layoutIfNeeded()
        }
        return frames
    }

    @Test func eachPlacementsCoveredArea() async {
        var report: [String] = []
        for variant in TerminalChipPage.Variant.allCases {
            for state in TerminalChipPage.states {
                let frames = await measure(variant, state)
                guard let chip = frames.chip, frames.lines.count == TerminalChipPage.lineCount else {
                    Issue.record("\(variant) \(state.word): unmeasured (chip \(String(describing: frames.chip)), \(frames.lines.count) lines)")
                    continue
                }
                let overText = frames.lines.values.reduce(0) { sum, line in
                    let cut = chip.intersection(line)
                    return sum + (cut.isNull ? 0 : cut.width * cut.height)
                }
                let linesHit = frames.lines.values.filter { $0.intersects(chip) }.count
                report.append(String(format: "%@ %@: chip %.0fx%.0f = %.0f pt², over output %.0f pt² (%d lines)",
                                     variant.rawValue, state.word, chip.width, chip.height,
                                     chip.width * chip.height, overText, linesHit))
                #expect(chip.width <= 201, "\(variant) \(state.word): \(chip.width) pt wide")
            }
        }
        print("TerminalChipCoverage: " + report.joined(separator: "; "))
        Attachment.record(report.joined(separator: "\n"), named: "chip-coverage.txt") // the step exports it
    }
}
#endif
