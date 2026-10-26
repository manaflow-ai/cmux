import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo, 2026-10-26: "i didnt want any glass. you're frosting the app's background which is
/// pointless?" A window that is not key looks exactly like the key one: the glass keeps its key look
/// (``ActiveLookGlassEffectView``) and no wash covers it. Only `appearance.inactiveWindowDim`, 0 by
/// default, dims a window that is not key.
@MainActor @Suite struct InactiveWindowTintTests {
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

    /// Inside a backdrop glass update, the glass's material read answers active whatever the key
    /// state; its other read (the traffic lights follow it) and every read outside get AppKit's.
    @Test func onlyTheGlassMaterialReadIsForcedActive() {
        var site: UInt?
        #expect(!ActiveLookScope.forcesActive(depth: 0, site: 10, materialSite: &site), "outside a glass update")
        #expect(site == nil)
        #expect(ActiveLookScope.forcesActive(depth: 1, site: 10, materialSite: &site), "the first read in the scope: the material")
        #expect(site == 10)
        #expect(!ActiveLookScope.forcesActive(depth: 1, site: 20, materialSite: &site), "the second read keeps AppKit's answer")
        #expect(ActiveLookScope.forcesActive(depth: 2, site: 10, materialSite: &site))
        #expect(!ActiveLookScope.forcesActive(depth: 0, site: 10, materialSite: &site))
    }

    /// The window backdrop's glass keeps its active look; other glass panels follow the key state
    /// as before.
    @Test func theWindowBackdropGlassKeepsItsActiveLook() {
        for material in Self.glassMaterials {
            let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            view.apply(WindowBackdrop(backgroundOpacity: 0.55, backgroundBlur: material == .glass(.clear) ? -2 : -1,
                                      liquidGlass: true), tint: .black)
            let glass = view.materialView as? GlassPanelView
            #expect(glass?.keepsActiveLook == true)
            if #available(macOS 26.0, *), glass?.isLiquidGlass == true {
                #expect(glass?.materialView is ActiveLookGlassEffectView)
            }
        }
        #expect(GlassPanelView().keepsActiveLook == false)
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
