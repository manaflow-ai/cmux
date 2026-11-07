import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// RESIZE P0 5 diagnostic (no merge): who marks LayoutRootView for layout between a key press and the end of frame 1.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeLayoutMarkDiagTests {
    typealias Ground = PaneGroundCoversPaneTests

    nonisolated(unsafe) static var recording = false
    nonisolated(unsafe) static var marks: [String] = []
    nonisolated(unsafe) static var classes: [String: Int] = [:]
    nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        typealias Setter = @convention(c) (NSView, Selector, Bool) -> Void
        let sel = #selector(setter: NSView.needsLayout)
        guard let method = class_getInstanceMethod(NSView.self, sel) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let block: @convention(block) (NSView, Bool) -> Void = { view, flag in
            if flag, recording {
                let name = String(describing: type(of: view))
                classes[name, default: 0] += 1
                if view is LayoutRootView || view is ScreenContentView, marks.count < 6 {
                    let stack = Thread.callStackSymbols.dropFirst(1).prefix(28).map { line in
                        line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
                    }
                    marks.append("MARK \(name) wasNeeds=\(view.needsLayout):\n  " + stack.joined(separator: "\n  "))
                }
            }
            original(view, sel, flag)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    @Test(arguments: [LayoutDirection.right, .down])
    func whoMarksTheRoot(direction: LayoutDirection) throws {
        Self.install()
        let rig = Ground.Rig(Ground.column(direction == .left || direction == .right ? Ground.pair : Ground.stack), focused: "p2")
        defer { rig.close() }
        rig.root.layoutSubtreeIfNeeded()
        rig.commit()
        Self.marks = []
        Self.classes = [:]
        Self.recording = true
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        let afterPress = rig.root.needsLayout
        let pressMarks = Self.marks.count
        _ = rig.root.advanceFrame(1.0 / 120)
        let afterAdvance = rig.root.needsLayout
        rig.root.layoutSubtreeIfNeeded()
        Self.recording = false
        let text = Self.classes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        Issue.record("DIAG \(direction): root needsLayout after press \(afterPress), after advance \(afterAdvance); marks in press \(pressMarks); classes [\(text)]\n\(Self.marks.joined(separator: "\n"))")
    }
}
