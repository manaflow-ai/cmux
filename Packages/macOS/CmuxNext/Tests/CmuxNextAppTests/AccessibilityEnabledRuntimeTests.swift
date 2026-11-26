import AppKit
@testable import CmuxNextApp
import ObjectiveC
import Testing

/// The "pressable but unindexed" class, checked in this macOS's Objective-C runtime.
///
/// CuaDriver (0.32.0) indexes an NSAccessibilityElement, so a computer-use client can press it,
/// only when it answers AXEnabled. AppKit lists the element's AXPress either way, so nothing else
/// fails: the onboarding "turn on" link (MessagesLabHome's TranscriptLinkElement) had AXPress and
/// stayed invisible to the onboarding walk until cmux#57734 overrode `isAccessibilityEnabled()`.
///
/// Every custom NSAccessibilityElement in cmux's image (CmuxNext and the MessagesLab packages,
/// all linked into this bundle) that implements an action must implement `isAccessibilityEnabled()`
/// too. Views are out of scope: NSView and NSControl answer AXEnabled themselves
/// (``pressableViewAnswersAXEnabled`` pins it).
@MainActor @Suite
struct AccessibilityEnabledRuntimeTests {
    /// The NSAccessibility methods that give an element an action a client can perform.
    static let actionSelectors: [Selector] = [
        NSSelectorFromString("accessibilityPerformPress"),
        NSSelectorFromString("accessibilityPerformIncrement"),
        NSSelectorFromString("accessibilityPerformDecrement"),
        NSSelectorFromString("accessibilityPerformConfirm"),
        NSSelectorFromString("accessibilityPerformCancel"),
        NSSelectorFromString("accessibilityPerformPick"),
        NSSelectorFromString("accessibilityPerformShowMenu"),
        NSSelectorFromString("accessibilityPerformRaise"),
        NSSelectorFromString("accessibilityPerformDelete"),
        NSSelectorFromString("accessibilityPerformShowAlternateUI"),
        NSSelectorFromString("accessibilityPerformShowDefaultUI"),
        NSSelectorFromString("accessibilityCustomActions"),
        NSSelectorFromString("accessibilityActionNames"),
        NSSelectorFromString("accessibilityPerformAction:"),
    ]
    static let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")

    /// The pressable elements cmux#57734 fixed; the walk must find each, or it checks nothing.
    static let knownPressable: Set<String> = [
        "CmuxNextDesign.AgentCursorTagElement",
        "CmuxNextSidebar.ProfileDotElement",
        "CmuxNextTabs.TabAccessibilityElement",
        "CmuxNextTabs.TabCloseAccessibilityElement",
        "MessagesLabHome.TranscriptLinkElement",
        "MessagesLabSidebar.SidebarAccessibilityRow",
    ]

    @Test func everyPressableAccessibilityElementAnswersAXEnabled() throws {
        let image = try #require(class_getImageName(CmuxApplication.self))
        // Names only, from cmux's own image: touching every class in the process (objc_copyClassList)
        // messages root classes such as JavaScriptCore's JSExport, which aborts.
        var count: UInt32 = 0
        let names = try #require(objc_copyClassNamesForImage(image, &count))
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        var pressable: Set<String> = []
        var offenders: [String] = []
        for index in 0 ..< Int(count) {
            guard let cls = objc_lookUpClass(names[index]) else { continue }
            let name = NSStringFromClass(cls)
            // This suite's fixtures share the image (private classes have mangled names).
            guard !name.contains("CmuxNextAppTests"), Self.isCustomElement(cls) else { continue }
            guard Self.implementsAction(cls) else { continue }
            pressable.insert(name)
            if !Self.implementsEnabled(cls) { offenders.append(name) }
        }
        let missing = Self.knownPressable.subtracting(pressable).sorted()
        #expect(missing.isEmpty, "the walk did not find these pressable elements: \(missing.joined(separator: ", "))")
        #expect(offenders.isEmpty, """
            \(offenders.count) NSAccessibilityElement subclass(es) implement an accessibility action but not \
            isAccessibilityEnabled(), so computer-use drivers (CuaDriver) do not index them and cannot press them. \
            Add `override func isAccessibilityEnabled() -> Bool { true }` (or the element's enabled state):
            \(offenders.sorted().joined(separator: "\n"))
            """)
    }

    /// The classifier on fixtures: a press without AXEnabled is caught, with it passes, and an
    /// element without actions is not asked for it.
    @Test func classifierCatchesAPressWithoutAXEnabled() {
        #expect(Self.isCustomElement(PressWithoutEnabledFixture.self))
        #expect(Self.implementsAction(PressWithoutEnabledFixture.self))
        #expect(!Self.implementsEnabled(PressWithoutEnabledFixture.self))
        #expect(Self.implementsAction(InheritedPressFixture.self))
        #expect(!Self.implementsEnabled(InheritedPressFixture.self))
        #expect(Self.implementsAction(PressWithEnabledFixture.self))
        #expect(Self.implementsEnabled(PressWithEnabledFixture.self))
        #expect(Self.implementsEnabled(InheritedEnabledFixture.self))
        #expect(!Self.implementsAction(StaticTextFixture.self))
        #expect(!Self.isCustomElement(NSView.self))
    }

    /// The premise that keeps views out of the walk: AppKit answers AXEnabled for an NSView that
    /// takes a press, so only NSAccessibilityElement subclasses need the override. If this fails,
    /// views need the same walk.
    @Test func pressableViewAnswersAXEnabled() {
        let view = PressableViewFixture(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Fixture")
        #expect(Self.attributeNames(of: view).contains(NSAccessibility.Attribute.enabled.rawValue))
        let element = PressWithEnabledFixture()
        element.setAccessibilityRole(.button)
        #expect(Self.attributeNames(of: element).contains(NSAccessibility.Attribute.enabled.rawValue))
    }

    /// A class whose AppKit ancestor is NSAccessibilityElement (not a view, which answers AXEnabled).
    static func isCustomElement(_ cls: AnyClass) -> Bool {
        var next: AnyClass? = class_getSuperclass(cls)
        while let current = next {
            if ObjectIdentifier(current) == ObjectIdentifier(NSAccessibilityElement.self) { return true }
            if ObjectIdentifier(current) == ObjectIdentifier(NSResponder.self) { return false }
            next = class_getSuperclass(current)
        }
        return false
    }

    static func implementsAction(_ cls: AnyClass) -> Bool {
        let own = ownSelectorsBelowElement(cls)
        return actionSelectors.contains { own.contains($0) }
    }

    static func implementsEnabled(_ cls: AnyClass) -> Bool {
        ownSelectorsBelowElement(cls).contains(enabledSelector)
    }

    /// The instance methods `cls` and its ancestors below NSAccessibilityElement implement.
    private static func ownSelectorsBelowElement(_ cls: AnyClass) -> Set<Selector> {
        var selectors: Set<Selector> = []
        var next: AnyClass? = cls
        while let current = next, ObjectIdentifier(current) != ObjectIdentifier(NSAccessibilityElement.self) {
            var count: UInt32 = 0
            if let list = class_copyMethodList(current, &count) {
                for index in 0 ..< Int(count) { selectors.insert(method_getName(list[index])) }
                free(list)
            }
            next = class_getSuperclass(current)
        }
        return selectors
    }

    /// What an AX client reads as the element's attribute names (AXUIElementCopyAttributeNames).
    private static func attributeNames(of object: NSObject) -> [String] {
        let selector = NSSelectorFromString("accessibilityAttributeNames")
        guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { return [] }
        return (value as? [String]) ?? []
    }
}

nonisolated private class PressWithoutEnabledFixture: NSAccessibilityElement {
    override func accessibilityPerformPress() -> Bool { true }
}

nonisolated private final class InheritedPressFixture: PressWithoutEnabledFixture {}

nonisolated private class PressWithEnabledFixture: NSAccessibilityElement {
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { true }
}

nonisolated private final class InheritedEnabledFixture: PressWithEnabledFixture {}

nonisolated private final class StaticTextFixture: NSAccessibilityElement {
    override func accessibilityLabel() -> String? { "text" }
}

private final class PressableViewFixture: NSView {
    override func accessibilityPerformPress() -> Bool { true }
}
