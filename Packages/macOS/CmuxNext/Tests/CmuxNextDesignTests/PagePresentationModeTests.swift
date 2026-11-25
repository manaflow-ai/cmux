@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The page presentation switch (InTreePages.Presentation): three launch-latched modes, child windows, in tree and
/// presented. `CMUX_PAGE_PRESENTATION` names one first, the older `CMUX_IN_TREE_PAGES` still works, then the Debug
/// Settings file (its new key, then the older on/off switch), then the build tag (`presented-pages…` presents,
/// `in-tree-pages…` is in tree). The Debug Settings row shows the mode the build runs in (the "Off while on" bug of
/// the in-tree switch, 34f21f2f), and an engine without the mode's calls falls back to child windows.
@MainActor @Suite(.serialized) struct PagePresentationModeTests {
    typealias Mode = InTreePages.Presentation

    @Test func theEnvironmentNamesTheModeFirst() {
        #expect(InTreePages.decide(fileOverride: .inTree, tag: "in-tree-pages", environment: ["CMUX_PAGE_PRESENTATION": "presented"])
                == (.presented, "environment"))
        #expect(InTreePages.decide(fileOverride: nil, tag: nil, environment: ["CMUX_PAGE_PRESENTATION": "childWindow"])
                == (.childWindow, "environment"))
        #expect(InTreePages.decide(fileOverride: nil, tag: nil, environment: ["CMUX_PAGE_PRESENTATION": "in_tree"]) == (.inTree, "environment"))
        // The new name wins over the older switch; an unknown name leaves the decision to the rest.
        #expect(InTreePages.decide(fileOverride: nil, tag: nil,
                                   environment: ["CMUX_PAGE_PRESENTATION": "presented", "CMUX_IN_TREE_PAGES": "1"]) == (.presented, "environment"))
        #expect(InTreePages.decide(fileOverride: nil, tag: "presented-pages-x",
                                   environment: ["CMUX_PAGE_PRESENTATION": "sideways"]) == (.presented, "tag"))
    }

    @Test func theOlderEnvironmentSwitchStillWorks() {
        #expect(InTreePages.decide(fileOverride: .presented, tag: nil, environment: ["CMUX_IN_TREE_PAGES": "1"]) == (.inTree, "environment"))
        #expect(InTreePages.decide(fileOverride: .presented, tag: "presented-pages", environment: ["CMUX_IN_TREE_PAGES": "0"])
                == (.childWindow, "environment"))
    }

    @Test func theFileThenTheTagThenTheDefault() {
        #expect(InTreePages.decide(fileOverride: .childWindow, tag: "presented-pages", environment: [:]) == (.childWindow, "file"))
        #expect(InTreePages.decide(fileOverride: nil, tag: "presented-pages", environment: [:]) == (.presented, "tag"))
        #expect(InTreePages.decide(fileOverride: nil, tag: "presented-pages-v2", environment: [:]) == (.presented, "tag"))
        #expect(InTreePages.decide(fileOverride: nil, tag: "in-tree-pages-fix", environment: [:]) == (.inTree, "tag"))
        #expect(InTreePages.decide(fileOverride: nil, tag: "other", environment: [:]) == (.childWindow, "default"))
    }

    @Test func theFileOverrideReadsTheNewKeyThenTheOlderSwitch() {
        #expect(InTreePages.fileOverride(in: ["browser.pagePresentation": "presented"]) == .presented)
        #expect(InTreePages.fileOverride(in: ["browser.pagePresentation": "childWindow", "browser.inTreePages": true]) == .childWindow)
        #expect(InTreePages.fileOverride(in: ["browser.inTreePages": true]) == .inTree)
        #expect(InTreePages.fileOverride(in: ["browser.inTreePages": false]) == .childWindow)
        #expect(InTreePages.fileOverride(in: [:]) == nil)
    }

    /// The row's default is the build's own mode, so a `presented-pages` build shows Presented, not Child windows.
    @Test func theRowShowsTheModeTheBuildRunsIn() {
        defer { InTreePages.shared.setForTesting(mode: nil) }
        InTreePages.shared.setForTesting(mode: nil)
        InTreePages.shared.latch(fileOverride: nil, tag: "presented-pages", environment: [:])
        #expect(InTreePages.shared.requested == .presented)
        #expect(InTreePages.tunable.descriptor.defaultValue == .choice("presented"))
        #expect(InTreePages.shared.presentationStatus == "pending: presented")
        #expect(InTreePages.shared.status == "off", "debug.cef in_tree reads off in the presented mode")
    }

    @Test func presentedPagesHaveNoPageWindowsButAreNotInTree() {
        defer { InTreePages.shared.setForTesting(mode: nil) }
        InTreePages.shared.setForTesting(mode: .presented, engine: .supported)
        #expect(InTreePages.shared.isPresented && InTreePages.shared.hasNoPageWindows)
        #expect(!InTreePages.shared.isActive, "the in-tree paths (the responder gate, in-tree hosting) stay off")
        #expect(InTreePages.shared.presentationStatus == "presented")
        InTreePages.shared.setForTesting(mode: .inTree, engine: .supported)
        #expect(InTreePages.shared.isActive && InTreePages.shared.hasNoPageWindows && !InTreePages.shared.isPresented)
        InTreePages.shared.setForTesting(mode: .childWindow, engine: .supported)
        #expect(!InTreePages.shared.hasNoPageWindows)
    }

    @Test func anEngineWithoutTheCallsFallsBackToChildWindows() {
        defer { InTreePages.shared.setForTesting(mode: nil) }
        InTreePages.shared.setForTesting(mode: .presented)
        InTreePages.shared.engineResolved(.unsupported("fork API 27 < 30"))
        #expect(InTreePages.shared.mode == .childWindow && !InTreePages.shared.hasNoPageWindows)
        #expect(InTreePages.shared.presentationStatus == "unsupported_fork: fork API 27 < 30")
    }

    @Test func theModeNamesParse() {
        #expect(Mode(name: "presented") == .presented && Mode(name: "inTree") == .inTree && Mode(name: "in-tree") == .inTree)
        #expect(Mode(name: "childWindow") == .childWindow && Mode(name: "child_window") == .childWindow && Mode(name: "nope") == nil)
    }
}
