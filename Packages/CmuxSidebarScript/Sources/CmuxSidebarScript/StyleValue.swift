import Foundation

/// A first-class style value in the Lisp, produced by constructors like
/// `(color ...)`, `(font ...)`, `(gradient ...)`. These are passed to view
/// options (`:color`, `:font`, ...) and never rendered on their own.
public enum StyleValue: Equatable {
    case color(RNColor)
    case font(RNFont)
    case gradient(RNGradient)
    case alignment(RNAlignment)
    case edges(RNEdges)
    case shadow(RNShadow)
    case action(RNAction)

    /// Projection into the render layer.
    var rnValue: RNValue {
        switch self {
        case .color(let c): return .color(c)
        case .font(let f): return .font(f)
        case .gradient(let g): return .gradient(g)
        case .alignment(let a): return .alignment(a)
        case .edges(let e): return .edges(e)
        case .shadow(let s): return .shadow(s)
        case .action(let a): return .action(a)
        }
    }
}
