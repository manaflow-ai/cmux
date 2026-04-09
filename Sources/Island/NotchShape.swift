// Sources/Island/NotchShape.swift
//
// Ported from https://github.com/farouqaldori/claude-island
//   ClaudeIsland/UI/Components/NotchShape.swift
// License: Apache 2.0. See THIRD_PARTY_LICENSES.md.
//
// Behavior-preserving port. Only the license header and the enclosing
// type name differ from the upstream source.

import SwiftUI

/// Notch-flanking shape with inward-curving top corners and outward-curving
/// bottom corners. Drawn as one contiguous path so the notch area itself is
/// never painted — the physical MacBook notch sits naturally in the middle
/// of the shape's top edge between the two inward curves.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Start at top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left inward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )

        // Left edge down
        path.addLine(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius)
        )

        // Bottom-left outward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY)
        )

        // Bottom-right outward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )

        // Right edge up
        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius)
        )

        // Top-right inward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )

        // Top edge back to start
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}
