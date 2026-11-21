import AppKit
@testable import CmuxNextAgentPane
import CmuxNextPages
import Foundation
import Testing

/// The React scene renderer's SF Symbols (`__appsymbol/<name>.png`, ``AppSceneSymbolImages``):
/// each symbol a bundled, sample or example app names draws as the native renderer draws it, so an
/// app pane on the React page keeps every glyph (#40428 review F1).
@MainActor @Suite struct AppSceneSymbolImagesTests {
    /// Every symbol name the apps in the repository pass (webviews/test/scene-symbols.test.tsx
    /// scans them and fails when this list differs).
    static let bundledSymbols: [String] = [
        "archivebox", "arrow.clockwise", "arrow.right.circle", "arrow.triangle.2.circlepath", "arrow.triangle.branch",
        "arrow.triangle.pull", "arrow.up.circle.fill", "arrow.up.right.square", "arrow.uturn.right.circle", "bell",
        "bolt.horizontal.circle", "book", "book.closed", "brain", "bubble.left", "bubble.left.and.bubble.right",
        "calendar", "checklist", "checkmark", "checkmark.circle", "checkmark.circle.fill", "checkmark.seal",
        "checkmark.square", "checkmark.square.fill", "chevron.down", "chevron.left",
        "chevron.left.forwardslash.chevron.right", "chevron.right", "chevron.up", "circle", "circle.dashed",
        "circle.dotted", "circle.fill", "circle.inset.filled", "clock", "clock.arrow.circlepath", "cloud",
        "cup.and.saucer", "curlybraces", "desktopcomputer", "display", "doc", "doc.badge.ellipsis", "doc.badge.plus",
        "doc.circle", "doc.on.doc", "doc.richtext", "doc.text", "doc.text.magnifyingglass", "ellipsis",
        "ellipsis.circle", "envelope", "exclamationmark.bubble", "exclamationmark.circle", "exclamationmark.triangle",
        "exclamationmark.triangle.fill", "eye", "folder", "folder.badge.plus", "folder.badge.questionmark",
        "gauge.with.dots.needle.0percent", "gauge.with.dots.needle.33percent", "gauge.with.needle",
        "gauge.with.needle.fill", "globe", "hammer.circle", "hourglass", "house", "infinity", "info.circle", "key",
        "laptopcomputer", "largecircle.fill.circle", "line.3.horizontal.decrease.circle", "link", "link.badge.plus",
        "list.bullet.rectangle", "lock", "magnifyingglass", "minus.circle", "moon", "network", "network.slash",
        "note.text", "number", "pencil", "person.2", "person.crop.circle", "person.crop.circle.badge.checkmark",
        "person.crop.circle.badge.exclamationmark", "person.crop.circle.badge.plus",
        "person.crop.circle.badge.questionmark", "photo", "pin.fill", "play", "play.circle", "play.fill",
        "play.rectangle", "plus", "plus.circle", "plusminus", "point.3.connected.trianglepath.dotted",
        "puzzlepiece.extension", "questionmark.bubble", "questionmark.circle", "rectangle.split.2x1", "rectangle.stack",
        "server.rack", "shield.lefthalf.filled", "shield.slash", "shippingbox", "sparkles", "square",
        "square.and.arrow.down", "square.and.pencil", "square.grid.2x2", "square.stack", "terminal", "terminal.fill",
        "text.badge.plus", "text.bubble", "text.magnifyingglass", "timer", "trash", "tray", "tray.full", "xmark",
        "xmark.circle", "xmark.circle.fill",
    ]

    @Test func everyBundledAppSymbolDraws() {
        let undrawn = Self.bundledSymbols.filter { AppSceneSymbolImages.draw($0) == nil }
        #expect(undrawn.isEmpty, "no drawing for \(undrawn)")
    }

    @Test func drawsAnySymbolAsATemplatePNGAndNothingElse() throws {
        let images = AppSceneSymbolImages()
        for name in ["cup.and.saucer", "circle", "chevron.right", "chevron.down", "desktopcomputer"] {
            let data = try #require(images.png(name), "\(name) draws")
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide > 0 && bitmap.hasAlpha)
        }
        #expect(images.png("not.a.real.sf.symbol.zz") == nil, "a name this Mac draws nothing for")
        for bad in ["../secret", "Cup", "a..b", ".a", "a b", ""] {
            #expect(images.png(bad) == nil, "\(bad) is not a symbol name")
        }
    }

    @Test func theScenePagesListTheSymbolPrefix() {
        #expect(PageDescriptor.appScene.dynamicPrefixes.contains(AppsPanelsPageProvider.symbolPrefix))
        #expect(PageDescriptor.agent.dynamicPrefixes.contains(AppsPanelsPageProvider.symbolPrefix))
    }
}
