import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// #49579: the sidebar's "cmux Is Up to Date" card drew its title at the sidebar rows' own size, its detail nearly
/// as big, and its own padding and corner (12 pt and 21 pt at Default), while the staged update card padded 5 pt and
/// Now Playing 6 pt. Every card now reads one type scale and one spacing (`CardScale.swift`), which follow the
/// density and the person's text size, so the cards match each other at every density.
@MainActor @Suite(.serialized) struct CardScaleDensityTests {
    private static func atEachDensity(_ body: (DensityPreset) throws -> Void) rethrows {
        for preset in DensityPreset.allCases {
            try DensityTokens.$scoped.withValue(preset.tokens) { try body(preset) }
        }
    }

    /// Default draws the scale's own steps: a 13 pt title, 12 pt body, 11 pt caption, and a 10 pt padding.
    @Test func defaultDensityDrawsTheTypeScaleSteps() {
        DensityTokens.$scoped.withValue(DensityPreset.cozy.tokens) {
            #expect(Typography.cardTitle.pointSize == TypeScale.Base.body * Typography.userScale)
            #expect(Typography.cardBody.pointSize == TypeScale.Base.detail * Typography.userScale)
            #expect(Typography.cardCaption.pointSize == TypeScale.Base.caption * Typography.userScale)
            #expect(Metrics.cardPadding == Metrics.space4 + Metrics.space1)
        }
    }

    /// At every density a card's title stays under the sidebar rows' title (the bug: they were the same size), its
    /// body under its title and its caption under its body, all on the half-point grid.
    @Test func cardTextStaysUnderTheRowsAtEveryDensity() {
        Self.atEachDensity { preset in
            let title = Typography.cardTitle.pointSize, body = Typography.cardBody.pointSize
            let caption = Typography.cardCaption.pointSize
            #expect(title < Typography.sidebarTitle.pointSize, "\(preset): card title \(title) is not under the rows' title")
            #expect(body < title && caption < body, "\(preset): \(title) / \(body) / \(caption) is not a scale")
            for size in [title, body, caption, Typography.dialogTitle.pointSize] {
                #expect((size * 2).rounded() == size * 2, "\(preset): \(size) is off the half-point grid")
            }
            #expect(Metrics.cardCornerRadius == Metrics.buttonContainer(padding: Metrics.cardPadding).outerRadius)
        }
    }

    /// The card's text and spacing grow with the density, from Ultra-compact to Spacious, as the rows do.
    @Test func cardScaleFollowsTheDensity() {
        var last: (title: CGFloat, body: CGFloat, padding: CGFloat)?
        Self.atEachDensity { preset in
            let now = (Typography.cardTitle.pointSize, Typography.cardBody.pointSize, Metrics.cardPadding)
            if let last {
                #expect(now.0 > last.title && now.1 > last.body, "\(preset): the card's text did not grow with the density")
                #expect(now.2 >= last.padding, "\(preset): the card's padding shrank as the density grew")
            }
            last = (now.0, now.1, now.2)
        }
    }

    /// The up-to-date notice, the staged update card and the Now Playing card share one padding, corner and type.
    @Test func sidebarCardsShareOnePaddingCornerAndType() throws {
        _ = NSApplication.shared
        try Self.atEachDensity { preset in
            let notice = SidebarNoticeCard(id: "update", symbol: nil, title: "cmux Is Up to Date",
                                           detail: "Version 1.0.0-nightly.4496387397801, checked just now", dismissLabel: "Dismiss")
            let noticeCard = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
            noticeCard.configure(notice)
            noticeCard.frame = NSRect(x: 0, y: 0, width: 240, height: noticeCard.height(for: notice, width: 240))
            noticeCard.layoutSubtreeIfNeeded()

            let update = SidebarUpdateCard(title: "Update Ready", detail: "nightly 3845050 · Oct 13", buttonTitle: "Restart to Update",
                                           automaticUpdatesTitle: "Automatic Updates", automaticUpdates: true,
                                           notes: SidebarUpdateCard.Notes(headline: "", keepsRunning: ""))
            let updateCard = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarUpdateCardView.height(for: update, layout: .card)))
            updateCard.configure(update)
            updateCard.layoutOverride = .card
            updateCard.layoutSubtreeIfNeeded()

            let pad = Metrics.cardPadding, corner = Metrics.cardCornerRadius
            #expect(noticeCard.titleLabel.frame.minX == pad, "\(preset): the notice's title is \(noticeCard.titleLabel.frame.minX) pt in, not \(pad)")
            #expect(updateCard.titleLabel.frame.minX == pad, "\(preset): the update card's title is \(updateCard.titleLabel.frame.minX) pt in, not \(pad)")
            #expect(noticeCard.titleLabel.frame.minY >= pad && updateCard.titleLabel.frame.minY >= pad)
            #expect(noticeCard.surface.cornerRadius == corner && updateCard.surface.cornerRadius == corner,
                    "\(preset): corners \(noticeCard.surface.cornerRadius) and \(updateCard.surface.cornerRadius), not \(corner)")
            #expect(noticeCard.titleLabel.font == Typography.cardTitle && updateCard.titleLabel.font == Typography.cardTitle)
            #expect(updateCard.detailLabel.font == Typography.cardBody)
            let detail = try #require(noticeCard.subviews.flatMap { [$0] + $0.subviews }.compactMap { $0 as? NSTextField }
                .first { $0.stringValue == notice.detail })
            #expect(detail.font == Typography.cardBody, "\(preset): the notice's detail is \(detail.font?.pointSize ?? 0) pt")
        }
    }

    /// Dialogs pad by the density's dialog padding and title in the scale's title step at that density.
    @Test func dialogsFollowTheDensity() {
        Self.atEachDensity { preset in
            #expect(CmuxDialogMetrics.cardPadding == Metrics.dialogPadding, "\(preset)")
            #expect(Typography.dialogTitle.pointSize == Typography.cardSize(TypeScale.Base.title), "\(preset)")
        }
    }

    /// Review of #49615: a toast's padding follows the density's spacing grid (its tuned 8 pt is Default's), so a
    /// toast's gaps grow with its text; an explicit tuning still sets the Default size.
    @Test func toastPaddingFollowsTheDensity() {
        var look = CmuxToastLook()
        look.shape = .rounded
        look.compact = false
        var tuning = CmuxToastTuning()
        var last: CGFloat?
        Self.atEachDensity { preset in
            let padding = CmuxToastView.geometry(look: look, tuning: tuning).padding
            #expect(padding == Metrics.scale(Metrics.tokens.space(tuning.padding)), "\(preset): toast padding \(padding)")
            if let last { #expect(padding >= last, "\(preset): the toast's padding shrank as the density grew") }
            last = padding
        }
        DensityTokens.$scoped.withValue(DensityPreset.cozy.tokens) {
            tuning.padding = 12
            #expect(CmuxToastView.geometry(look: look, tuning: tuning).padding == Metrics.scale(12), "a tuned padding is Default's size")
        }
    }

    /// Review of #49615: the password reveal dialog's preview and the other read-only fields take the card scale, so
    /// they grow with the dialog's title and buttons.
    @Test func dialogCodeTextFollowsTheDensity() {
        Self.atEachDensity { preset in
            #expect(Typography.cardMonospaced(TypeScale.Base.body).pointSize == Typography.cardMessage.pointSize, "\(preset)")
        }
        let small = DensityTokens.$scoped.withValue(DensityPreset.ultraCompact.tokens) { Typography.cardMonospaced(TypeScale.Base.body).pointSize }
        let large = DensityTokens.$scoped.withValue(DensityPreset.spacious.tokens) { Typography.cardMonospaced(TypeScale.Base.body).pointSize }
        #expect(large > small, "the preview kept \(small) pt from Ultra-compact to Spacious")
    }
}
