import AppKit
import CmuxFoundation
import SwiftUI

/// Shared draggable find bar for panels whose content is rendered by WebKit.
struct WebViewFindBar: View {
    @Binding var needle: String
    let selected: UInt?
    let total: UInt?
    let accessibilityIdentifier: String
    let focusRequestGeneration: UInt64
    let selectAllOnFocusRequest: Bool
    let selectionOwner: AnyObject
    let canApplyFocusRequest: (UInt64) -> Bool
    let onFieldDidFocus: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    @State private var corner: WebViewFindBarCorner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero

    private let padding: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                searchField
                searchButton(
                    systemName: "chevron.up",
                    help: String(localized: "search.nextMatch.help", defaultValue: "Next match (Return)"),
                    action: onNext
                )
                searchButton(
                    systemName: "chevron.down",
                    help: String(localized: "search.previousMatch.help", defaultValue: "Previous match (Shift+Return)"),
                    action: onPrevious
                )
                searchButton(
                    systemName: "xmark",
                    help: String(localized: "search.close.help", defaultValue: "Close (Esc)"),
                    action: onClose
                )
            }
            .padding(8)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)
            .background {
                GeometryReader { barGeometry in
                    Color.clear.onAppear {
                        barSize = barGeometry.size
                    }
                }
            }
            .padding(padding)
            .offset(dragOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            .gesture(dragGesture(in: geometry.size))
        }
    }

    private var searchField: some View {
        WebViewFindTextField(
            text: $needle,
            accessibilityIdentifier: accessibilityIdentifier,
            focusRequestGeneration: focusRequestGeneration,
            selectAllOnFocusRequest: selectAllOnFocusRequest,
            selectionOwner: selectionOwner,
            canApplyFocusRequest: canApplyFocusRequest,
            onFieldDidFocus: onFieldDidFocus,
            onEscape: onClose,
            onReturn: { isShift in
                isShift ? onPrevious() : onNext()
            }
        )
        .frame(width: 180)
        .padding(.leading, 8)
        .padding(.trailing, 50)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .trailing) {
            matchCount
        }
    }

    @ViewBuilder
    private var matchCount: some View {
        if let selected {
            let totalText = total.map(String.init) ?? "?"
            countLabel("\(selected + 1)/\(totalText)")
        } else if let total {
            countLabel(total == 0 ? "0/0" : "-/\(total)")
        }
    }

    private func countLabel(_ text: String) -> some View {
        Text(text)
            .cmuxFont(.caption)
            .foregroundColor(.secondary)
            .monospacedDigit()
            .padding(.trailing, 8)
    }

    private func searchButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(SearchButtonStyle())
        .safeHelp(help)
    }

    private func dragGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let center = corner.centerPosition(in: containerSize, barSize: barSize, padding: padding)
                let translatedCenter = CGPoint(
                    x: center.x + value.translation.width,
                    y: center.y + value.translation.height
                )
                withAnimation(.easeOut(duration: 0.2)) {
                    corner = WebViewFindBarCorner.closest(to: translatedCenter, in: containerSize)
                    dragOffset = .zero
                }
            }
    }
}
