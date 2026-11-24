import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// RFD 0125 D10's Page Info looks (``PageInfoLook``): today's stays the default, the launch variable picks a
/// redraw, and each redraw's numbers sit on the shared menu and card tokens.
@MainActor
struct PageInfoLookTests {
    @Test func todayIsTheDefault() {
        #expect(PageInfoLook.from(environment: [:]) == .current)
        #expect(PageInfoLook.from(environment: [PageInfoLook.environmentKey: "nonsense"]) == .current)
        #expect(PageInfoLook.current.geometry == nil)
        #expect(PageInfoLook.drawing(.band) { PageInfoLook.active } == .band)
    }

    @Test func theLaunchVariablePicksALook() {
        for look in PageInfoLook.allCases {
            #expect(PageInfoLook.from(environment: [PageInfoLook.environmentKey: look.rawValue.uppercased()]) == look)
        }
    }

    @Test func menuSitsOnTheMenuGrid() throws {
        let menu = try #require(PageInfoLook.menu.geometry)
        #expect(menu.rowHeight == DesignTokens.controlRow)
        #expect(menu.fillRadius == MenuMetrics.highlightRadius)
        #expect(menu.cardPadding == MenuMetrics.highlightInset)
        // The icon and the separator start where a menu's do, from the bubble's edge.
        #expect(menu.cardPadding + menu.rowLeading == MenuMetrics.iconX)
        #expect(menu.cardPadding + menu.separatorInset == MenuMetrics.separatorInset)
        #expect(menu.cardPadding + menu.textX == MenuMetrics.textX(iconColumn: true))
        #expect(menu.cornerRadius == GlassMenuMaterial.menuCornerRadius(surface: DesignTokens.radiusPopup))
        #expect(!menu.sectionCards && !menu.headerIsBand)
    }

    @Test func cardsAreConcentricWithTheBubble() throws {
        let card = try #require(PageInfoLook.card.geometry)
        #expect(card.cornerRadius == DesignTokens.radiusCard)
        #expect(card.sectionCards)
        // A section card's radius (the bubble's less its padding) is the rows' highlight radius.
        #expect(card.cornerRadius - card.cardPadding == card.fillRadius)
    }

    @Test func bandHeaderIsThePaneHeadersHeight() throws {
        let band = try #require(PageInfoLook.band.geometry)
        #expect(band.headerIsBand)
        #expect(band.headerHeight == DesignTokens.controlPrimary)
        #expect(band.cardPadding == 0 && band.separatorInset == 0)
    }

    @Test func theCardLookPutsSectionsOnCardsWithoutSeparators() {
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(string: "https://example.com"), kind: .web(.secure))
        model.permissions = [SitePermissionState(kind: .camera, setting: .allow, isDefault: false)]
        let page = PageInfoLook.drawing(.card) { PageInfoPages(model: model, send: { _ in }).build() } as? NSStackView
        let arranged = page?.arrangedSubviews ?? []
        #expect(arranged.first is PageInfoHeaderView)
        #expect(!arranged.contains { $0.identifier == PageInfoPages.separatorID })
        // Security, permissions, then cookies and site settings: three cards.
        #expect(arranged.filter { $0.subviews.contains { $0 is CardSurfaceView } }.count == 3)
    }

    @Test func todaysPageKeepsItsSeparators() {
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(string: "https://example.com"), kind: .web(.secure))
        model.permissions = [SitePermissionState(kind: .camera, setting: .allow, isDefault: false)]
        let page = PageInfoLook.drawing(.current) { PageInfoPages(model: model, send: { _ in }).build() } as? NSStackView
        #expect((page?.arrangedSubviews ?? []).filter { $0.identifier == PageInfoPages.separatorID }.count == 2)
    }
}
