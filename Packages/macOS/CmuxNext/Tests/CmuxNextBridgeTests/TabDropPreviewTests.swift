import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBridge

/// tab-dnd (Lawrence 2026-10-04): the drop performs exactly the previewed
/// target; a stay changes nothing; a refusal commits nothing; outside
/// every window the preview is a new window.
struct TabDropPreviewTests {
    let strip = UUID()
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

    func context(paneTabs: Int = 3, workspaceTabs: Int = 5, dragged: Int = 1, group: Bool = false) -> TabDragContext {
        var context = TabDragContext(sourcePaneID: "pane-a", sourcePaneTabCount: paneTabs, sourceWorkspaceID: "ws-1",
                                     sourceWorkspaceTabCount: workspaceTabs, draggedTabCount: dragged, sourceStripID: strip,
                                     sourceIndex: 0)
        context.isGroupDrag = group
        return context
    }

    func resolve(_ kind: TabDropKind, _ context: TabDragContext) -> TabDropResolution {
        TabDragResolver.resolve(TabDropProposal(kind: kind, highlightFrame: frame), insideWindow: true, screenPoint: .zero,
                                context: context)
    }

    /// Every accepted kind previews itself and commits the outcome of that
    /// same kind, on the same rect.
    @Test func anAcceptedTargetCommitsWhatItPreviews() {
        let kinds: [(TabDropKind, TabDragOutcome)] = [
            (.strip(stripID: strip, index: 2, groupID: "g"), .strip(stripID: strip, index: 2, groupID: "g")),
            (.newSplit(paneID: "pane-b", edge: .left), .newSplit(paneID: "pane-b", edge: .left)),
            (.newColumn(screenID: "s", afterColumnID: "c1"), .newColumn(screenID: "s", afterColumnID: "c1")),
            (.newDock(screenID: "s", edge: "top"), .newDock(screenID: "s", edge: "top")),
            (.newWorkspace(groupID: nil, index: 2), .newWorkspace(groupID: nil, index: 2)),
            (.workspace(id: "ws-2"), .workspace(id: "ws-2")),
        ]
        for (kind, outcome) in kinds {
            let resolution = resolve(kind, context())
            #expect(resolution.preview == .target(TabDropProposal(kind: kind, highlightFrame: frame)), "\(kind)")
            #expect(resolution.outcome == outcome, "\(kind)")
            #expect(resolution.refusal == nil)
        }
    }

    /// The own place shows a preview (the outline on it) and changes nothing.
    @Test func theOwnPlaceIsAStayPreview() {
        for kind in [TabDropKind.strip(stripID: strip, index: 0, groupID: nil), .workspace(id: "ws-1")] {
            let resolution = resolve(kind, context())
            #expect(resolution.preview == .stay(TabDropProposal(kind: kind, highlightFrame: frame)), "\(kind)")
            #expect(resolution.outcome == .cancel)
        }
    }

    /// A target that cannot run carries its refusal and commits nothing.
    @Test func aRefusedTargetCarriesItsReason() {
        let cases: [(TabDropKind, TabDragContext, TabDropRefusal)] = [
            (.newSplit(paneID: "pane-a", edge: .right), context(paneTabs: 1), .splitEmptiesPane),
            (.newColumn(screenID: "s", afterColumnID: nil), context(), .columnBeforeFirst),
            (.newDock(screenID: "s", edge: "bottom"), context(dragged: 2, group: true), .groupDock),
        ]
        for (kind, context, refusal) in cases {
            let resolution = resolve(kind, context)
            #expect(resolution.preview == .refused(TabDropProposal(kind: kind, highlightFrame: frame), refusal), "\(kind)")
            #expect(resolution.refusal == refusal)
            #expect(resolution.outcome == .cancel)
        }
    }

    /// Lawrence 2026-10-05: a refused zone does not highlight (no outline,
    /// no reason, no toast on the drop); every other preview does.
    @Test func aRefusedZoneDoesNotHighlight() {
        let refused = resolve(.newSplit(paneID: "pane-a", edge: .right), context(paneTabs: 1))
        #expect(!refused.preview.highlights)
        #expect(resolve(.newSplit(paneID: "pane-b", edge: .right), context()).preview.highlights)
        #expect(resolve(.strip(stripID: strip, index: 0, groupID: nil), context()).preview.highlights)
    }

    /// A surface that refuses at a point (a sidebar row of another
    /// machine) is a refusal there, with its own reason.
    @Test func aSurfaceRefusalPreviewsWithItsReason() {
        let proposal = TabDropProposal(kind: .newWorkspace(groupID: nil, index: -1), highlightFrame: frame,
                                       refusedReason: "Tabs stay on their machine.")
        let resolution = TabDragResolver.resolve(proposal, insideWindow: true, screenPoint: .zero, context: context())
        #expect(resolution.preview == .refused(proposal, .surface("Tabs stay on their machine.")))
        #expect(resolution.outcome == .cancel)
    }

    @Test func outsideEveryWindowThePreviewIsANewWindow() {
        let point = CGPoint(x: 900, y: 40)
        let tearOff = TabDragResolver.resolve(nil, insideWindow: false, screenPoint: point, context: context())
        #expect(tearOff.preview == .newWindow(screenPoint: point))
        #expect(tearOff.outcome == .tearOff(screenPoint: point))
        let move = TabDragResolver.resolve(nil, insideWindow: false, screenPoint: point, context: context(paneTabs: 1, workspaceTabs: 1))
        #expect(move.preview == .newWindow(screenPoint: point))
        #expect(move.outcome == .moveWindow(screenPoint: point))
    }

    /// The preview kind and the outcome agree for every kind and context:
    /// an outcome other than cancel only ever comes with a target preview
    /// of the same rect.
    @Test func noOutcomeWithoutItsPreview() {
        let kinds: [TabDropKind] = [
            .strip(stripID: strip, index: 0, groupID: nil), .strip(stripID: strip, index: 3, groupID: nil),
            .newSplit(paneID: "pane-a", edge: .top), .newSplit(paneID: "pane-b", edge: .bottom),
            .newColumn(screenID: "s", afterColumnID: nil), .newColumn(screenID: "s", afterColumnID: "c"),
            .newDock(screenID: "s", edge: "top"), .newWorkspace(groupID: "g", index: -1),
            .workspace(id: "ws-1"), .workspace(id: "ws-2"),
        ]
        let contexts = [context(), context(paneTabs: 1), context(paneTabs: 2, dragged: 2, group: true), context(paneTabs: 1, workspaceTabs: 1)]
        for kind in kinds {
            for context in contexts {
                let resolution = resolve(kind, context)
                switch resolution.preview {
                case .target(let proposal):
                    #expect(proposal.kind == kind)
                    #expect(resolution.outcome != .cancel, "\(kind) previews a target but commits nothing")
                case .stay, .refused:
                    #expect(resolution.outcome == .cancel, "\(kind) previews no change but commits \(resolution.outcome)")
                case .newWindow, .none:
                    Issue.record("\(kind) inside a window previews \(resolution.preview)")
                }
            }
        }
    }
}

/// tab-dnd: a drag over a web page resolves against the window hosting the
/// page. Chromium pages are child windows ordered above the content window;
/// the window pick looks through them, the overlay panel and the ghost.
struct TabDragWindowPickTests {
    let content = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func aWebPageWindowAboveTheContentDoesNotHideIt() {
        let ordered: [TabDragWindowPick.Candidate] = [
            .init(frame: CGRect(x: 600, y: 300, width: 200, height: 40), controllerID: nil),   // drag ghost
            .init(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), controllerID: nil),    // overlay plane panel
            .init(frame: CGRect(x: 400, y: 0, width: 800, height: 760), controllerID: nil),   // Chromium page
            .init(frame: content, controllerID: "w1"),
        ]
        #expect(TabDragWindowPick.frontmost(at: CGPoint(x: 700, y: 320), in: ordered) == "w1")
    }

    @Test func theFrontmostContentWindowWinsAndOutsideIsNil() {
        let ordered: [TabDragWindowPick.Candidate] = [
            .init(frame: CGRect(x: 500, y: 0, width: 600, height: 600), controllerID: "front"),
            .init(frame: CGRect(x: 0, y: 0, width: 900, height: 900), controllerID: "hidden", isVisible: false),
            .init(frame: content, controllerID: "back"),
        ]
        #expect(TabDragWindowPick.frontmost(at: CGPoint(x: 600, y: 100), in: ordered) == "front")
        #expect(TabDragWindowPick.frontmost(at: CGPoint(x: 100, y: 100), in: ordered) == "back")
        #expect(TabDragWindowPick.frontmost(at: CGPoint(x: 2000, y: 100), in: ordered) == nil)
    }
}
