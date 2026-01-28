import AppKit
import Foundation
import SwiftUI

/// A pill-shaped button that displays update status and provides access to update actions.
struct UpdatePill: View {
    @ObservedObject var model: UpdateViewModel
    @State private var showPopover = false
    @State private var resetTask: Task<Void, Never>?

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
                .onChange(of: model.effectiveState) { newState in
                    resetTask?.cancel()
                    if case .notFound(let notFound) = newState, model.overrideState == nil {
                        recordUITestTimestamp(key: "noUpdateShownAt")
                        resetTask = Task { [weak model] in
                            let delay = UInt64(UpdateTiming.noUpdateDisplayDuration * 1_000_000_000)
                            try? await Task.sleep(nanoseconds: delay)
                            guard !Task.isCancelled, case .notFound? = model?.state else { return }
                            await MainActor.run {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    recordUITestTimestamp(key: "noUpdateHiddenAt")
                                    model?.state = .idle
                                }
                            }
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

    private func recordUITestTimestamp(key: String) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MODE"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_TIMING_PATH"] else { return }

        let url = URL(fileURLWithPath: path)
        var payload: [String: Double] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            payload = object
        }
        payload[key] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url)
        }
#endif
    }
}
