import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the three ways the workspace hover card can say who made a workspace and why
/// (`WorkspaceHoverCardOrigin.Style`; Leo 2026-11-19: "acpmux should expose these a lot better"), for an agent, an
/// agent with no purpose and a script, then a workspace the person made, which shows nothing new. The real card
/// view on the real overlay glass (`AAWorkspaceHoverCardVariantsGalleryTests.render`), dark and light. Written under
/// `hover-card-origin/`, with `all.png` the sheet for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAWorkspaceHoverCardOriginGalleryTests {
    typealias Variants = AAWorkspaceHoverCardVariantsGalleryTests

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "hover-card-origin")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let now = WorkspaceHoverCardFixture.now
        var cases: [(String, SidebarWorkspaceOrigin?, WorkspaceHoverCardOrigin.Style)] = []
        for style in WorkspaceHoverCardOrigin.Style.allCases {
            for (state, origin) in WorkspaceHoverCardGallery.originStates where origin != nil {
                let shipped = style == WorkspaceHoverCardOrigin.shipped ? " (shipped)" : ""
                cases.append(("\(style.rawValue)\(shipped): \(state)", origin, style))
            }
        }
        cases.append(("person: nothing new", nil, WorkspaceHoverCardOrigin.shipped))
        var shots: [Bool: [CGImage]] = [true: [], false: []]
        for dark in [true, false] {
            for (index, (label, origin, style)) in cases.enumerated() {
                let image = try Variants.labeled(
                    try Variants.render(dark: dark) { WorkspaceHoverCardGallery.originView(origin, style, now: now) },
                    label, dark: dark)
                shots[dark]?.append(image)
                try AAGroupHeaderDensityGalleryTests.write(
                    image, to: out.appending(path: "\(index)-\(style.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try Variants.sheet(shots[true] ?? [], shots[false] ?? [], columns: 3),
                                                   to: out.appending(path: "all.png"))
    }
}
