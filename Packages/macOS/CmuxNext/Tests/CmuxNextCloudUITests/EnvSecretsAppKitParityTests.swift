#if DEBUG
import AppKit
@testable import CmuxNextCloudUI
import Testing

/// Environment Secrets Playground in AppKit: the places it drew differently from its SwiftUI first version,
/// checked on the drawn view (``EnvRenderedPage``) or on its laid-out view tree (``EnvLaidOutPage``).
@MainActor @Suite struct EnvSecretsAppKitParityTests {
    /// Sentences, Terminal state: as in a terminal, every line is one visual line, shown in full (no wrap, no
    /// ellipsis), so the `cmux secrets list` columns line up. A frame wider than the 680-point column scrolls
    /// sideways inside its own scroll view, and that scroll view sits in the page's scroll, so the page still
    /// scrolls as a whole.
    @Test func sentencesTerminalShowsEveryLineInFull() throws {
        let model = EnvSecretsPlaygroundModel()
        model.direction = .sentences
        model.scene = .cli
        let page = EnvLaidOutPage(model)
        let lines = page.all(NSTextField.self).filter { $0.font?.isFixedPitch == true && !$0.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(lines.count > 10, "the two terminal frames draw their lines (\(lines.count) found)")
        let cut = lines.filter { !page.showsInFull($0) }.map(\.stringValue)
        #expect(cut.isEmpty, "terminal lines cut off: \(cut)")
        let wrapped = lines.filter { !page.isOneLine($0) }.map(\.stringValue)
        #expect(wrapped.isEmpty, "terminal lines on more than one visual line: \(wrapped)")
        let columns = try #require(lines.first { $0.stringValue.hasPrefix("NAME ") }, "the list's column header line is drawn")
        #expect(columns.stringValue.hasSuffix("LAST USE") && page.isOneLine(columns), "every column title is on the header's one line")

        let header = try #require(page.label(startingWith: "Values every chat in this environment"), "the page header is drawn")
        let pageScroll = try #require(header.enclosingScrollView, "the page scrolls")
        let frameScroll = try #require(columns.enclosingScrollView, "the list frame has a scroll view")
        #expect(frameScroll !== pageScroll, "the list frame scrolls sideways on its own, not with the page")
        #expect(frameScroll.hasHorizontalScroller, "the list frame scrolls sideways")
        #expect(frameScroll.enclosingScrollView === pageScroll, "the list frame sits in the page's scroll")
        let document = try #require(frameScroll.documentView)
        #expect(document.frame.width > frameScroll.contentView.bounds.width,
                "the list is wider (\(document.frame.width)) than its frame (\(frameScroll.contentView.bounds.width)), so it scrolls")
    }

    /// Ledger, Paste state: each row's type menu reads as a borderless menu, as in SwiftUI: the type's symbol
    /// and short name in the text colour and a small chevron in the text colour, with no badge fill behind them.
    @Test func ledgerTypeMenuIsALabelAndAChevronWithNoBadge() throws {
        let model = EnvSecretsPlaygroundModel()
        model.direction = .ledger
        model.scene = .paste
        let page = EnvLaidOutPage(model)
        let shorts = Set(EnvSecretsKind.allCases.map(\.short))
        let menus = page.all(EnvClickArea.self).filter { area in
            guard let stack = area.subviews.first as? NSStackView, stack.arrangedSubviews.last is NSImageView else { return false }
            return page.all(NSTextField.self, in: area).contains { shorts.contains($0.stringValue) }
        }
        #expect(menus.count >= 4, "the review rows draw their type menus (\(menus.count) found)")
        for menu in menus {
            let name = try #require(page.all(NSTextField.self, in: menu).first { shorts.contains($0.stringValue) })
            let chevron = try #require((menu.subviews.first as? NSStackView)?.arrangedSubviews.last as? NSImageView)
            #expect(name.textColor == EnvInk.text, "\"\(name.stringValue)\" is in the text colour, not \(String(describing: name.textColor))")
            #expect(chevron.contentTintColor == EnvInk.text, "the chevron after \"\(name.stringValue)\" is in the text colour")
            #expect(chevron.fittingSize.height < name.fittingSize.height, "the chevron is smaller than the name")
            let fills = page.all(EnvBox.self, in: menu).filter { $0.fill != nil }
            #expect(fills.isEmpty, "\"\(name.stringValue)\" sits on \(fills.count) badge fill(s)")
        }
    }

    /// Inspector, Revoke state: the sheet casts two shadows, as the SwiftUI sheet did: a tight contact shadow
    /// (blur 2, 1 point down, 10 %) and a soft drop (blur 18, 8 points down, 18 %), both the sheet's size.
    @Test func inspectorRevokeSheetHasTheTwoLayerShadow() throws {
        let model = EnvSecretsPlaygroundModel()
        model.direction = .inspector
        model.scene = .revoke
        let page = EnvLaidOutPage(view: EnvInspectorDirection(model: model, reload: {}).make(), size: CGSize(width: 1180, height: 820))
        let sheetTitle = try #require(page.label(startingWith: "Revoke STRIPE_SECRET_KEY now?"), "the sheet's title is drawn")
        let shadowed = page.all(NSView.self).filter { $0.shadow != nil }
        func layer(blur: CGFloat) -> NSView? { shadowed.first { abs(($0.shadow?.shadowBlurRadius ?? -1) - blur) < 0.01 } }
        let contact = try #require(layer(blur: 2), "a contact shadow with blur 2; shadows found: \(shadowed.compactMap { $0.shadow?.shadowBlurRadius })")
        let drop = try #require(layer(blur: 18), "a drop shadow with blur 18")
        for (view, alpha, down) in [(contact, 0.10, 1.0), (drop, 0.18, 8.0)] {
            let shadow = try #require(view.shadow)
            let opacity = shadow.shadowColor?.usingColorSpace(.sRGB)?.alphaComponent ?? 0
            #expect(abs(opacity - alpha) < 0.005, "blur \(shadow.shadowBlurRadius): opacity \(opacity), want \(alpha)")
            #expect(shadow.shadowOffset == NSSize(width: 0, height: -down), "blur \(shadow.shadowBlurRadius): offset \(shadow.shadowOffset)")
            let sheet = try #require(view.superview, "the shadow layer sits in the sheet's holder")
            #expect(view.frame == sheet.bounds, "blur \(shadow.shadowBlurRadius): the layer is the sheet's size")
            #expect(sheetTitle.isDescendant(of: sheet), "blur \(shadow.shadowBlurRadius): the layer is under the revoke sheet")
        }
    }

    /// Inspector, Paste state: in a narrow window the type notes wrap onto a second line, none cut off.
    @Test func inspectorTypeNotesWrapInANarrowWindow() throws {
        let model = EnvSecretsPlaygroundModel()
        model.scene = .paste
        let view = EnvInspectorDirection(model: model, reload: {}).make()
        let page = try EnvRenderedPage(view: view, size: CGSize(width: 640, height: 900))
        #expect(page.cutLines.isEmpty, "lines cut off: \(page.cutLines)")
        #expect(page.text.contains("only to the hosts below."), "the API secret note is drawn to its end")
        #expect(page.text.contains("before the agent starts."), "the setup note is drawn to its end")
    }

    /// Sentences, Saved state: the highlighted card (the open secret) has a 1.5-point border, as the plain
    /// cards' 1-point border is not.
    @Test func sentencesHighlightedCardBorderIsOneAndAHalfPoints() throws {
        let model = EnvSecretsPlaygroundModel()
        model.direction = .sentences
        model.scene = .saved
        let page = try EnvRenderedPage(model)
        let title = try #require(page.line(containing: "STRIPE_SECRET_KEY"), "the highlighted card's title is drawn")
        #expect(page.accentEdgeWidth(leftOf: title) == 1.5, "border \(page.accentEdgeWidth(leftOf: title)) pt")
    }
}
#endif
