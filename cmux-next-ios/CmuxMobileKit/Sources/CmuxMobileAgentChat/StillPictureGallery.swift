#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileMarkdown
import CmuxSpinner
import SwiftUI
import UIKit

/// The stand-ins a tab card's still picture draws where a live row would show a UIKit-backed view (a
/// typeset formula, a turning spinner, a menu), each in three variants. A, first, is the one the app
/// draws. Leo, 2026-11-23, on the yellow-and-red placeholders: "just do it properly". Each row is
/// drawn through `ImageRenderer`, as the tab grid's pictures are, so a shot shows the picture itself,
/// not the live view. Launch with `-cmux-mobile-recovery-gallery stills`, optionally with a theme
/// (`-cmux-mobile-gallery-appearance light|dark`, or after `theme-mocha` or `theme-solarized`).
public struct StillPictureGallery: View {
    private let theme = CmuxMobileTheme.standard
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    public init() {}

    static let tex = #"\int_0^1 x^2\,dx = \tfrac{1}{3}"#

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Math", variants: [
                    ("A", AnyView(MarkdownBlockView(block: MarkdownBlock(id: 0, kind: .math(Self.tex)), margin: 0))),
                    ("B", AnyView(mathInset)),
                    ("C", AnyView(mathChip)),
                ])
                section("Running tool", variants: [
                    ("A", AnyView(toolRow { CmuxSpinner(size: 14) })),
                    ("B", AnyView(toolRow { CmuxSpinner(size: 14, tint: theme.colors.accent.color) })),
                    ("C", AnyView(toolRow { Circle().fill(theme.colors.label3.color).frame(width: 8, height: 8) })),
                ])
                section("Menu", variants: [
                    ("A", AnyView(menuLabel)),
                    ("B", AnyView(HStack(spacing: 4) { menuLabel; Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(theme.colors.label3.color) })),
                    ("C", AnyView(menuLabel.padding(.horizontal, 10).padding(.vertical, 5).background(theme.colors.fill.color, in: .capsule))),
                ])
            }
            .padding(20)
        }
        .background(CmuxMobileBackdrop().ignoresSafeArea())
        .accessibilityIdentifier("stillPictureGallery")
    }

    /// B: the source in the code face on the code ground, with a function mark.
    private var mathInset: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "function").foregroundStyle(theme.colors.label3.color)
            Text(Self.tex).font(.callout.monospaced()).foregroundStyle(theme.colors.label2.color).lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.codeBg.color, in: .rect(cornerRadius: 8, style: .continuous))
    }

    /// C: a chip naming a formula, no source.
    private var mathChip: some View {
        Label("Formula", systemImage: "function")
            .font(.footnote.weight(.medium))
            .foregroundStyle(theme.colors.label2.color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(theme.colors.fill.color, in: .capsule)
    }

    private func toolRow<Mark: View>(@ViewBuilder _ mark: () -> Mark) -> some View {
        HStack(spacing: 8) {
            mark()
            Text("Running tests").font(.subheadline).foregroundStyle(theme.colors.label2.color)
        }
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(theme.colors.label2.color)
            .frame(minWidth: 24, minHeight: 24)
    }

    private func section(_ title: String, variants: [(String, AnyView)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(theme.colors.label.color)
            ForEach(variants, id: \.0) { name, view in
                HStack(alignment: .top, spacing: 12) {
                    Text(name).font(.caption.monospaced().weight(.bold)).foregroundStyle(theme.colors.label3.color)
                        .frame(width: 14)
                    picture(of: view)
                }
            }
        }
        .padding(14)
        .background(theme.colors.surface.color, in: .rect(cornerRadius: 14, style: .continuous))
    }

    /// The view as a tab card's picture draws it: the still environment, through `ImageRenderer`.
    @ViewBuilder private func picture(of view: AnyView) -> some View {
        if let image = still(view) {
            Image(uiImage: image)
        } else {
            Text(verbatim: "no picture").foregroundStyle(theme.colors.danger.color)
        }
    }

    private func still(_ view: AnyView) -> UIImage? {
        let renderer = ImageRenderer(content: view
            .drawnAsStillPicture()
            .environment(\.colorScheme, scheme)
            .frame(width: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true))
        renderer.scale = scale
        return renderer.uiImage
    }
}
#endif
