import AppKit
import Bonsplit
import Foundation
import SwiftUI

// MARK: - UpdatePill

/// A pill-shaped button that displays update status and provides access to update actions.
struct UpdatePill: View {
    // MARK: SwiftUI Properties

    @ObservedObject var model: UpdateViewModel

    @State private var showPopover = false

    // MARK: Properties

    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    // MARK: Computed Properties

    private var textWidth: CGFloat? {
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let size = (model.maxWidthText as NSString).size(withAttributes: attributes)
        return size.width
    }

    // MARK: Content Properties

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

    private var pillButton: some View {
        Button(action: {
            if case let .notFound(notFound) = model.state {
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
                    .frame(maxWidth: textWidth, alignment: .leading)
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
        .safeHelp(model.text)
        .accessibilityLabel(model.text)
        .accessibilityIdentifier("UpdatePill")
    }
}

// MARK: - InstallUpdateMenuItem

/// Menu item that shows "Install Update and Relaunch" when an update is ready.
struct InstallUpdateMenuItem: View {
    // MARK: SwiftUI Properties

    @ObservedObject var model: UpdateViewModel

    // MARK: Content Properties

    var body: some View {
        if model.state.isInstallable {
            Button(String(localized: "update.installAndRelaunch", defaultValue: "Install Update and Relaunch")) {
                model.state.confirm()
            }
        }
    }
}
