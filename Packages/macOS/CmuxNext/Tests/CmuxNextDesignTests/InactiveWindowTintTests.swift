import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing
import CmuxNextDesignTokens

/// Leo, 2026-10-26: "i didnt want any glass. you're frosting the app's background which is
/// pointless?" A window that is not key looks exactly like the key one: the glass keeps its key look
/// (``ActiveLookGlassEffectView``) and no wash covers it. Only `appearance.inactiveWindowDim`, 0 by
/// default, dims a window that is not key.
@MainActor @Suite(.closesItsWindows) struct InactiveWindowTintTests {
    static let glassMaterials: [WindowMaterial] = [.glass(.regular), .glass(.clear)]
    static let materials: [WindowMaterial] = glassMaterials + [.frosted, .translucent, .opaque]

    /// A key window never has a wash, whatever the material or dim.
    @Test func aKeyWindowHasNoWash() {
        for material in Self.materials {
            for dim in [0.0, 0.3, 1.0] {
                #expect(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: true, dim: dim) == 0)
            }
        }
    }

    /// Under the default settings a window that is not key gets what the key one gets: zero wash.
    @Test func theInactiveStateMatchesTheKeyStateByDefault() {
        let dim = CGFloat(DesignSettings().inactiveWindowDim)
        #expect(dim == 0, "appearance.inactiveWindowDim is off by default")
        for material in Self.materials {
            let key = WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: true, dim: dim)
            let notKey = WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, dim: dim)
            #expect(key == 0 && notKey == key, "\(material): no wash in front or behind")
        }
    }

    /// One update's calibration reads show a pair only when they come from one caller at exactly
    /// two sites (the glass's material and traffic-light reads), in any order.
    @Test func calibrationFindsOnlyTheGlassPair() {
        typealias Read = ActiveLookScope.Read
        #expect(ActiveLookScope.pair(in: [Read(site: 1860, caller: 7), Read(site: 1584, caller: 7)]) == [1584, 1860])
        #expect(ActiveLookScope.pair(in: [Read(site: 1584, caller: 7), Read(site: 1860, caller: 7), Read(site: 1584, caller: 7)]) == [1584, 1860])
        #expect(ActiveLookScope.pair(in: [Read(site: 30, caller: 7), Read(site: 20, caller: 7), Read(site: 10, caller: 7)]) == nil,
                "three sites: not the glass")
        #expect(ActiveLookScope.pair(in: [Read(site: 1584, caller: 7), Read(site: 1860, caller: 8)]) == nil, "two callers")
        #expect(ActiveLookScope.pair(in: [Read(site: 1584, caller: 7)]) == nil)
    }

    /// The first update with the pair fixes the material site (a new window can lose focus right
    /// after its first layout: the fleet probe drew the frost there with two confirmations); an
    /// update showing no pair resets. Calibration reads keep AppKit's answer, so nothing is forced
    /// before the site is fixed.
    @Test func theFirstUpdateWithThePairFixesTheMaterialSite() {
        var candidate: (pair: [UInt], count: Int)?
        #expect(ActiveLookScope.confirm(nil, candidate: &candidate) == nil)
        #expect(candidate == nil, "an update with no pair resets")
        #expect(ActiveLookScope.confirm([1584, 1860], candidate: &candidate) == 1584, "the lower site: the material read")
    }

    /// The reader is the first AppKit frame and the graph is found by its SwiftUI frames, by the
    /// images' paths (a swizzled AppKit method can live in another image).
    @Test func framesAreClassifiedByTheirImagePath() {
        #expect(ActiveLookScope.imageKind(path: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit") == .appKit)
        #expect(ActiveLookScope.imageKind(path: "/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore") == .swiftUI)
        #expect(ActiveLookScope.imageKind(path: "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI") == .swiftUI)
        #expect(ActiveLookScope.imageKind(path: "/Applications/cmux.app/Contents/MacOS/cmux") == .other)
        #expect(ActiveLookScope.imageKind(path: "") == .other)
    }

    /// Only a window that has held an `ActiveLookGlassEffectView` keeps the glass's key look; a
    /// window with plain glass alone (popups, the palette) follows the key state.
    @Test func onlyTheBackdropWindowKeepsTheActiveLook() {
        guard #available(macOS 26.0, *) else { return }
        func window() -> NSWindow {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = NSView()
            return window
        }
        let shell = window(), popup = window(), scope = ActiveLookScope()
        defer { shell.closeAfterTest() }
        defer { popup.closeAfterTest() }
        shell.contentView?.addSubview(ActiveLookGlassEffectView(scope: scope))
        popup.contentView?.addSubview(NSGlassEffectView())
        #expect(scope.keepsActiveLook(shell))
        #expect(!scope.keepsActiveLook(popup))
    }

    /// The key look lasts only while an `ActiveLookGlassEffectView` is in the window: a backdrop
    /// that leaves (an opaque or frosted material replaced it) or moves away hands the window's
    /// glass back to the key state; two backdrops count separately.
    @Test func theActiveLookEndsWhenTheBackdropGlassLeaves() {
        guard #available(macOS 26.0, *) else { return }
        func window() -> NSWindow {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = NSView()
            return window
        }
        let first = window(), second = window(), scope = ActiveLookScope()
        defer { first.closeAfterTest() }
        defer { second.closeAfterTest() }
        let glass = ActiveLookGlassEffectView(scope: scope), other = ActiveLookGlassEffectView(scope: scope)
        first.contentView?.addSubview(glass)
        first.contentView?.addSubview(other)
        other.removeFromSuperview()
        #expect(scope.keepsActiveLook(first), "one backdrop is still in it")
        second.contentView?.addSubview(glass)
        #expect(!scope.keepsActiveLook(first), "moved away")
        #expect(scope.keepsActiveLook(second))
        glass.removeFromSuperview()
        #expect(!scope.keepsActiveLook(second), "removed")
    }

    /// Only the window whose backdrop glass is updating is in scope, the innermost when updates
    /// nest; an unrelated window never is, and nothing is after the update.
    @Test func theScopeNamesOnlyTheUpdatingWindow() {
        let first = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        defer { first.closeAfterTest() }
        let second = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        defer { second.closeAfterTest() }
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        let scope = ActiveLookScope()
        #expect(scope.scopedWindow == nil)
        scope.during(first) {
            #expect(scope.scopedWindow == ObjectIdentifier(first))
            scope.during(second) { #expect(scope.scopedWindow == ObjectIdentifier(second)) }
            #expect(scope.scopedWindow == ObjectIdentifier(first))
            scope.during(nil) { #expect(scope.scopedWindow == ObjectIdentifier(first)) }
        }
        #expect(scope.scopedWindow == nil)
    }

    /// The window backdrop's glass keeps its active look through the app's scope; other glass
    /// panels, and a backdrop given no scope, follow the key state as before.
    @Test func theWindowBackdropGlassKeepsItsActiveLook() {
        let scope = ActiveLookScope()
        for material in Self.glassMaterials {
            let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), images: .shared, activeLook: scope)
            view.apply(WindowBackdrop(backgroundOpacity: 0.55, backgroundBlur: material == .glass(.clear) ? -2 : -1,
                                      liquidGlass: true), tint: .black)
            let glass = view.materialView as? GlassPanelView
            #expect(glass?.keepsActiveLook == true)
            if #available(macOS 26.0, *), glass?.isLiquidGlass == true {
                #expect(glass?.materialView is ActiveLookGlassEffectView)
            }
        }
        #expect(GlassPanelView().keepsActiveLook == false)
        let plain = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        plain.apply(WindowBackdrop(backgroundOpacity: 0.55, backgroundBlur: -1, liquidGlass: true), tint: .black)
        #expect((plain.materialView as? GlassPanelView)?.keepsActiveLook == false)
    }

    /// Only the dim covers a window that is not key, clamped to 0...1; an opaque window never
    /// gets one (theme color over the same theme color).
    @Test func onlyTheDimCoversAWindowThatIsNotKey() {
        for material in Self.glassMaterials + [.frosted, .translucent] {
            #expect(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, dim: 0) == 0)
            #expect(abs(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, dim: 0.2) - 0.2) < 0.0001)
            #expect(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, dim: 7) == 1)
            #expect(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, dim: -1) == 0)
        }
        #expect(WindowMaterialView.inactiveTintAlpha(material: .opaque, isKeyWindow: false, dim: 0.5) == 0)
    }

    /// Leo, 2026-10-23: a dim stays below the person's in-app background, so losing focus never
    /// dims or hides that art.
    @Test func theInactiveWashStaysBehindInAppArt() {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let wash = view.subviews.firstIndex(of: view.inactiveTintView)
        let art = view.subviews.firstIndex(of: view.artView)
        #expect(wash != nil && art != nil && wash! < art!, "the wash must be below the in-app background")
    }
}
