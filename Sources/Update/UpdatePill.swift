import AppKit
import SwiftUI

/// A pill-shaped button that displays update status and provides access to update actions.
struct UpdatePill: View {
    @ObservedObject var model: UpdateViewModel
    var showWhenIdle: Bool = false
    var idleText: String = "Check for Updates"
    var onIdleTap: (() -> Void)?
    @State private var showPopover = false
    @State private var resetTask: Task<Void, Never>?

    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var body: some View {
        if !model.state.isIdle || showWhenIdle {
            pillButton
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    UpdatePopoverView(model: model)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .onChange(of: model.state) { newState in
                    resetTask?.cancel()
                    if case .notFound(let notFound) = newState {
                        resetTask = Task { [weak model] in
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled, case .notFound? = model?.state else { return }
                            model?.state = .idle
                            notFound.acknowledgement()
                        }
                    } else {
                        resetTask = nil
                    }
                }
        }
    }

    @ViewBuilder
    private var pillButton: some View {
        Button(action: {
            if model.state.isIdle && showWhenIdle {
                if let onIdleTap {
                    onIdleTap()
                } else {
                    showPopover.toggle()
                }
                return
            }
            if case .notFound(let notFound) = model.state {
                model.state = .idle
                notFound.acknowledgement()
            } else {
                showPopover.toggle()
            }
        }) {
            HStack(spacing: 6) {
                if model.state.isIdle && showWhenIdle {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                } else {
                    UpdateBadge(model: model)
                        .frame(width: 14, height: 14)
                }

                Text(displayText)
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
        .help(displayText)
        .accessibilityLabel(displayText)
    }

    private var textWidth: CGFloat? {
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let text = model.state.isIdle && showWhenIdle ? idleText : model.maxWidthText
        let size = (text as NSString).size(withAttributes: attributes)
        return size.width
    }

    private var displayText: String {
        model.state.isIdle && showWhenIdle ? idleText : model.text
    }
}
