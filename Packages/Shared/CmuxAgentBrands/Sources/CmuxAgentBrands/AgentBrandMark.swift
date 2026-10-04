import SwiftUI

/// An agent's brand mark, or the generic agent glyph when it has none.
///
/// `.mono` (the default) paints with the current foreground style, so it tints like an SF Symbol in
/// sidebars, menus and selected rows. `.brand` paints the owner's colors for the color scheme.
/// Without `label` the mark is decoration beside text that already names the agent.
public struct AgentBrandMark: View {
    private let agent: String?
    private let size: CGFloat
    private let style: AgentBrandStyle
    private let label: Text?
    @Environment(\.colorScheme) private var colorScheme

    public init(agent: String?, size: CGFloat = 16, style: AgentBrandStyle = .mono, label: Text? = nil) {
        self.agent = agent
        self.size = size
        self.style = style
        self.label = label
    }

    public var body: some View {
        Group {
            if let spec = AgentBrandCatalog.spec(forAgent: agent) {
                AgentBrandCanvas(spec: spec, style: style, dark: colorScheme == .dark)
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .modifier(AgentBrandAccessibility(label: label))
    }
}

/// Draws one spec: brand through the shared Core Graphics renderer, mono through SwiftUI's
/// foreground shading so the mark follows `foregroundStyle` and tint.
struct AgentBrandCanvas: View {
    let spec: AgentBrandSpec
    let style: AgentBrandStyle
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            switch style {
            case .brand:
                context.withCGContext { cg in
                    AgentBrandRenderer.draw(spec, in: cg, rect: rect, style: .brand, dark: dark, monoColor: CGColor(gray: 0, alpha: 1))
                }
            case .mono:
                guard let transform = AgentBrandRenderer.transform(for: spec, in: rect, style: .mono) else { return }
                for item in spec.paths where item.monoOpacity > 0 {
                    guard let cgPath = AgentBrandRenderer.path(item.d) else { continue }
                    let path = Path(cgPath).applying(transform)
                    var layer = context
                    layer.opacity = item.monoOpacity
                    if let width = item.strokeWidth {
                        layer.stroke(path, with: .foreground, lineWidth: width * transform.a)
                    } else {
                        layer.fill(path, with: .foreground, style: FillStyle(eoFill: item.evenOdd))
                    }
                }
            }
        }
    }
}

private struct AgentBrandAccessibility: ViewModifier {
    let label: Text?
    func body(content: Content) -> some View {
        if let label {
            content.accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityAddTraits(.isImage)
        } else {
            content.accessibilityHidden(true)
        }
    }
}
