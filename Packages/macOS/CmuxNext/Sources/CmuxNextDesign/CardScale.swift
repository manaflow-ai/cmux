public import AppKit

/// The one type scale and spacing of every card the app shows over chrome: the sidebar's notice, update and Now
/// Playing cards, toasts and dialogs (#49579: the "cmux Is Up to Date" card drew its title at the sidebar rows' size,
/// with its own padding and corner, and each card had drifted to its own). Each size is a step of ``TypeScale``
/// (title 13, body 12, caption 11 at the Default density) times the density's text factor and the person's Text Size
/// and Interface Size, on the half-point grid, so every card grows and shrinks with the rest of the chrome.
///
/// | token              | Ultra-compact | Compact | Default | Comfortable | Spacious |
/// |--------------------|---------------|---------|---------|-------------|----------|
/// | ``cardTitle``      | 10.5          | 11.5    | 13      | 14.5        | 15.5     |
/// | ``cardBody``       | 9.5           | 11      | 12      | 13          | 14.5     |
/// | ``cardCaption``    | 9             | 10      | 11      | 12          | 13       |
public extension Typography {
    /// The density's text size over Default's, times the person's Text Size and Interface Size (1 at Default).
    static var cardTextFactor: CGFloat {
        let reference = DensityPreset.referenceTokens.textSize(compact: 12, comfortable: 13)
        return Metrics.tokens.textSize(compact: 12, comfortable: 13) / max(1, reference) * userScale
    }

    /// `step` (a ``TypeScale/Base`` size, drawn for Default) at the active density and text size, on the half-point grid.
    static func cardSize(_ step: CGFloat) -> CGFloat { (step * cardTextFactor * 2).rounded() / 2 }

    /// A card's title ("cmux Is Up to Date", a toast's two-line heading): ``TypeScale/Base/body``, emphasized.
    static var cardTitle: NSFont { system(.default, size: cardSize(TypeScale.Base.body), weight: TypeScale.emphasis) }
    /// A card's one-line message in the title's size, not emphasized (a one-line toast).
    static var cardMessage: NSFont { system(.default, size: cardSize(TypeScale.Base.body), weight: TypeScale.regular) }
    /// A card's detail, list lines and controls' labels: ``TypeScale/Base/detail``.
    static var cardBody: NSFont { system(.default, size: cardSize(TypeScale.Base.detail), weight: TypeScale.regular) }
    /// ``cardBody`` with tabular digits: a count that ticks (a download's bytes) keeps its width.
    static var cardBodyDigits: NSFont { system(.monospacedDigit, size: cardSize(TypeScale.Base.detail), weight: TypeScale.regular) }
    /// A card's text buttons and its button rows' titles: ``cardBody``'s size, emphasized.
    static var cardButton: NSFont { system(.default, size: cardSize(TypeScale.Base.detail), weight: TypeScale.emphasis) }
    /// A card's eyebrow, shortcut hints and other quiet labels: ``TypeScale/Base/caption``.
    static var cardCaption: NSFont { system(.default, size: cardSize(TypeScale.Base.caption), weight: TypeScale.regular) }
    /// A dialog's title: ``TypeScale/Base/title``, emphasized, at the density's text size.
    static var dialogTitle: NSFont { system(.default, size: cardSize(TypeScale.Base.title), weight: TypeScale.emphasis) }
    /// A card's or dialog's code text (a password preview, a pairing code): `step` in the monospaced face, at the density's
    /// text size, so it grows with the title and buttons around it.
    static func cardMonospaced(_ step: CGFloat, weight: NSFont.Weight = TypeScale.regular) -> NSFont {
        system(.monospaced, size: cardSize(step), weight: weight)
    }
}

/// The spacing every card shares (``Typography/cardTitle`` is its type): one padding on every side, the gap under the
/// title and the gap before a row of controls, all on the density's spacing grid and the interface scale.
public extension Metrics {
    /// Points from the edge of a card that holds text and buttons (the sidebar's notice, tip and update cards) to its
    /// content, the same on every side: ``space4`` and ``space1``, 10 pt at the Default density (#49579: the notice card
    /// drew 12 and the update card 5). It follows the density and the interface scale.
    static var cardPadding: CGFloat { space4 + space1 }

    /// The gap between a card's title and the detail under it: ``space1`` (2 pt at Default).
    static var cardTextGap: CGFloat { space1 }

    /// The gap between a card's text and a row of its controls, and between two such rows: ``space3`` (6 pt at Default).
    static var cardRowGap: CGFloat { space3 }

    /// Every card's corner, concentric with its buttons: the button corner plus ``cardPadding``.
    static var cardCornerRadius: CGFloat { buttonContainer(padding: cardPadding).outerRadius }

    /// A modal dialog's padding: ``space6`` (16 pt at Default), so a dialog follows the density as the cards do.
    static var dialogPadding: CGFloat { space6 }
}
