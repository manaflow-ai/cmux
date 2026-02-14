import AppKit
import Foundation
import SwiftUI

/// A pill-shaped button that displays update status and provides access to update actions.
struct UpdatePill: View {
    @ObservedObject var model: UpdateViewModel
    @State private var showPopover = false

    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var body: some View {
        let state = model.effectiveState
        if !state.isIdle {
            pillButton
                .popover(
                    isPresented: $showPopover,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    UpdatePopoverView(model: model)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    @ViewBuilder
    private var pillButton: some View {
        Button(action: {
            if case .notFound(let notFound) = model.state {
                model.state = .idle
                notFound.acknowledgement()
            } else {
                showPopover.toggle()
            }
        }) {
            HStack(spacing: 6) {
                UpdateBadge(model: model)
                    .frame(width: 14, height: 14)

                Text(model.text)
                    .font(Font(textFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: textWidth)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(model.backgroundColor)
            )
            .foregroundColor(model.foregroundColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.text)
        .accessibilityLabel(model.text)
        .accessibilityIdentifier("UpdatePill")
    }

    private var textWidth: CGFloat? {
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let size = (model.maxWidthText as NSString).size(withAttributes: attributes)
        return size.width
    }
}
