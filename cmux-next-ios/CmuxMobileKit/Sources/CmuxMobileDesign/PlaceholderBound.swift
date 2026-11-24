#if os(iOS)
import SwiftUI

/// A view drawn in place of real content while that content is on its way (a skeleton row, a
/// stand-in thumbnail, a spinner where text goes) says how long it may stay: its bound. Leo,
/// 2026-11-24: "wer need to chase all these placeholders doen and prevent them". The rule is
/// last-known state or nothing; a placeholder is allowed only for the first moments, never as a
/// state the phone can sit in.
///
/// Two checks read the bound, both named `ios-placeholder-bounds`:
/// - headless, on every pull request (scripts/ci/ios_placeholder_bounds.py): every placeholder
///   construct in the app's sources sits under `.placeholderBound`, and every id it names is in
///   cmux-next-ios/design/placeholders.json with a finite bound;
/// - on the simulator (UITests/PlaceholderBoundUITests.swift): Leo's flows are driven with
///   `-cmux-placeholder-markers`, which draws each placeholder's marker, and a marker still on
///   screen after its bound fails the run.
///
/// Without the launch argument the modifier adds nothing to the view or its accessibility tree.
public struct PlaceholderBound: ViewModifier {
    public let id: String
    public let bound: Duration

    /// The simulator check's launch argument; read once.
    public static let markersEnabled = ProcessInfo.processInfo.arguments.contains("-cmux-placeholder-markers")

    /// The identifier the UI check queries: `placeholder.<id>.<bound in ms>`.
    public static func identifier(_ id: String, bound: Duration) -> String {
        let ms = bound.components.seconds * 1000 + bound.components.attoseconds / 1_000_000_000_000_000
        return "placeholder.\(id).\(ms)"
    }

    public func body(content: Content) -> some View {
        if Self.markersEnabled {
            content.overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier(Self.identifier(id, bound: bound))
            }
        } else {
            content
        }
    }
}

public extension View {
    /// Marks this view as a placeholder that may stay on screen at most `bound`
    /// (cmux-next-ios/design/placeholders.json lists every id and why it waits).
    func placeholderBound(_ id: String, _ bound: Duration) -> some View {
        modifier(PlaceholderBound(id: id, bound: bound))
    }
}
#endif
