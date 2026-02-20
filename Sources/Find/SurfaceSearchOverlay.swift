import Bonsplit
import SwiftUI
import AppKit

struct SurfaceSearchOverlay: View {
    let surface: TerminalSurface
    @ObservedObject var searchState: TerminalSurface.SearchState
    let onClose: () -> Void
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @FocusState private var isSearchFieldFocused: Bool

    private let padding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                TextField("Search", text: $searchState.needle)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .padding(.leading, 8)
                    .padding(.trailing, 50)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1))
                    .cornerRadius(6)
                    .focused($isSearchFieldFocused)
                    .overlay(alignment: .trailing) {
                    if let selected = searchState.selected {
                        let totalText = searchState.total.map { String($0) } ?? "?"
                        Text("\(selected + 1)/\(totalText)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, 8)
                    } else if let total = searchState.total {
                        Text("-/\(total)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, 8)
                    }
                }
                .onExitCommand {
                    if searchState.needle.isEmpty {
                        onClose()
                    } else {
                        surface.hostedView.moveFocus()
                    }
                }
                .backport.onKeyPress(.return) { modifiers in
                    let action = modifiers.contains(.shift)
                    ? "navigate_search:previous"
                    : "navigate_search:next"
                    _ = surface.performBindingAction(action)
                    return .handled
                }

                Button(action: {
                    #if DEBUG
                    dlog("findbar.next surface=\(surface.id.uuidString.prefix(5))")
                    #endif
                    _ = surface.performBindingAction("navigate_search:next")
                }) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(SearchButtonStyle())
                .help("Next match (Return)")

                Button(action: {
                    #if DEBUG
                    dlog("findbar.prev surface=\(surface.id.uuidString.prefix(5))")
                    #endif
                    _ = surface.performBindingAction("navigate_search:previous")
                }) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(SearchButtonStyle())
                .help("Previous match (Shift+Return)")

                Button(action: {
                    #if DEBUG
                    dlog("findbar.close surface=\(surface.id.uuidString.prefix(5))")
                    #endif
                    onClose()
                }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(SearchButtonStyle())
                .help("Close (Esc)")
            }
            .padding(8)
            .background(.background)
            .clipShape(clipShape)
            .shadow(radius: 4)
            .onAppear {
                NSLog("Find: overlay appear tab=%@ surface=%@", surface.tabId.uuidString, surface.id.uuidString)
                findDebugLog(
                    "terminal.overlay.appear tab=\(surface.tabId.uuidString) surface=\(surface.id.uuidString) container=\(Int(geo.size.width))x\(Int(geo.size.height))"
                )
                logFindDebugSnapshot(
                    label: "terminal.overlay.appear",
                    window: surface.hostedView.window ?? NSApp.keyWindow,
                    focusView: surface.hostedView
                )
                isSearchFieldFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttySearchFocus)) { notification in
                guard notification.object as? TerminalSurface === surface else { return }
                NSLog("Find: overlay focus tab=%@ surface=%@", surface.tabId.uuidString, surface.id.uuidString)
                findDebugLog(
                    "terminal.overlay.focus tab=\(surface.tabId.uuidString) surface=\(surface.id.uuidString) container=\(Int(geo.size.width))x\(Int(geo.size.height))"
                )
                logFindDebugSnapshot(
                    label: "terminal.overlay.focus.pre",
                    window: surface.hostedView.window ?? NSApp.keyWindow,
                    focusView: surface.hostedView
                )
                DispatchQueue.main.async {
                    isSearchFieldFocused = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    Task { @MainActor in
                        logFindDebugSnapshot(
                            label: "terminal.overlay.focus.post",
                            window: surface.hostedView.window ?? NSApp.keyWindow,
                            focusView: surface.hostedView
                        )
                    }
                }
            }
            .background(
                GeometryReader { barGeo in
                    Color.clear
                        .onAppear {
                            barSize = barGeo.size
                            findDebugLog(
                                "terminal.overlay.barSize.appear tab=\(surface.tabId.uuidString) surface=\(surface.id.uuidString) bar=\(Int(barGeo.size.width))x\(Int(barGeo.size.height))"
                            )
                        }
                        .onChange(of: barGeo.size) { _, newSize in
                            barSize = newSize
                            findDebugLog(
                                "terminal.overlay.barSize.change tab=\(surface.tabId.uuidString) surface=\(surface.id.uuidString) bar=\(Int(newSize.width))x\(Int(newSize.height))"
                            )
                        }
                }
            )
            .padding(padding)
            .offset(dragOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        let centerPos = centerPosition(for: corner, in: geo.size, barSize: barSize)
                        let newCenter = CGPoint(
                            x: centerPos.x + value.translation.width,
                            y: centerPos.y + value.translation.height
                        )
                        let newCorner = closestCorner(to: newCenter, in: geo.size)
                        withAnimation(.easeOut(duration: 0.2)) {
                            corner = newCorner
                            dragOffset = .zero
                        }
                    }
            )
        }
    }

    private var clipShape: some Shape {
        RoundedRectangle(cornerRadius: 8)
    }

    enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var alignment: Alignment {
            switch self {
            case .topLeft: return .topLeading
            case .topRight: return .topTrailing
            case .bottomLeft: return .bottomLeading
            case .bottomRight: return .bottomTrailing
            }
        }
    }

    private func centerPosition(for corner: Corner, in containerSize: CGSize, barSize: CGSize) -> CGPoint {
        let halfWidth = barSize.width / 2 + padding
        let halfHeight = barSize.height / 2 + padding

        switch corner {
        case .topLeft:
            return CGPoint(x: halfWidth, y: halfHeight)
        case .topRight:
            return CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
        case .bottomLeft:
            return CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
        case .bottomRight:
            return CGPoint(x: containerSize.width - halfWidth, y: containerSize.height - halfHeight)
        }
    }

    private func closestCorner(to point: CGPoint, in containerSize: CGSize) -> Corner {
        let midX = containerSize.width / 2
        let midY = containerSize.height / 2

        if point.x < midX {
            return point.y < midY ? .topLeft : .bottomLeft
        }
        return point.y < midY ? .topRight : .bottomRight
    }
}

struct SearchButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
            .padding(.horizontal, 2)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .backport.pointerStyle(.link)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.primary.opacity(0.2)
        }
        if isHovered {
            return Color.primary.opacity(0.1)
        }
        return Color.clear
    }
}

private let findDebugEnvKey = "CMUX_DEBUG_FIND_LAYERING"
private let findDebugDefaultsKey = "cmuxDebugFindLayering"

@MainActor
func isFindDebugLayeringEnabled() -> Bool {
    if let envOverride = findDebugEnvOverride() {
        return envOverride
    }
    return UserDefaults.standard.bool(forKey: findDebugDefaultsKey)
}

@MainActor
func findDebugLog(_ message: @autoclosure () -> String) {
    guard isFindDebugLayeringEnabled() else { return }
    NSLog("FindDebug: %@", message())
}

@MainActor
func logFindDebugSnapshot(
    label: String,
    window: NSWindow?,
    focusView: NSView? = nil,
    maxDepth: Int = 6
) {
    guard isFindDebugLayeringEnabled() else { return }
    guard let window else {
        findDebugLog("\(label) window=nil")
        return
    }

    findDebugLog(
        "\(label) window=\(window.windowNumber) key=\(NSApp.keyWindow === window ? 1 : 0) firstResponder=\(describeResponder(window.firstResponder))"
    )

    if let focusView {
        findDebugLog("\(label) focusView=\(describeView(focusView))")
        var chain: [String] = []
        var current: NSView? = focusView
        var hops = 0
        while let view = current, hops < 24 {
            chain.append(describeView(view))
            current = view.superview
            hops += 1
        }
        if !chain.isEmpty {
            findDebugLog("\(label) focusSuperviewChain=\(chain.joined(separator: " -> "))")
        }
    }

    if let themeFrame = window.contentView?.superview {
        findDebugLog("\(label) themeFrameSubviews=\(themeFrame.subviews.count)")
        for (index, subview) in themeFrame.subviews.enumerated() {
            findDebugLog("\(label) theme[\(index)] \(describeView(subview))")
        }
    }

    guard let root = window.contentView?.superview ?? window.contentView else {
        findDebugLog("\(label) window has no content view")
        return
    }

    var lines: [String] = []
    collectFindDebugLines(
        root,
        depth: 0,
        maxDepth: maxDepth,
        focusView: focusView,
        verbose: findDebugVerboseModeEnabled(),
        output: &lines
    )

    if lines.isEmpty {
        findDebugLog("\(label) no matching views under root \(describeView(root))")
        return
    }

    let lineLimit = 120
    for line in lines.prefix(lineLimit) {
        findDebugLog("\(label) \(line)")
    }
    if lines.count > lineLimit {
        findDebugLog("\(label) ... truncated \(lines.count - lineLimit) more lines")
    }
}

private func findDebugEnvOverride() -> Bool? {
    guard let raw = ProcessInfo.processInfo.environment[findDebugEnvKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
          !raw.isEmpty else {
        return nil
    }

    switch raw {
    case "1", "true", "yes", "on", "all":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return nil
    }
}

private func findDebugVerboseModeEnabled() -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[findDebugEnvKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() else {
        return false
    }
    return raw == "all"
}

private func collectFindDebugLines(
    _ view: NSView,
    depth: Int,
    maxDepth: Int,
    focusView: NSView?,
    verbose: Bool,
    output: inout [String]
) {
    if shouldIncludeFindDebugView(view, focusView: focusView, verbose: verbose) {
        let indent = String(repeating: "  ", count: depth)
        output.append("\(indent)\(describeView(view))")
    }

    guard depth < maxDepth else { return }
    for subview in view.subviews {
        collectFindDebugLines(
            subview,
            depth: depth + 1,
            maxDepth: maxDepth,
            focusView: focusView,
            verbose: verbose,
            output: &output
        )
    }
}

private func shouldIncludeFindDebugView(_ view: NSView, focusView: NSView?, verbose: Bool) -> Bool {
    if verbose { return true }

    let name = String(describing: type(of: view)).lowercased()
    let looksFindRelated = name.contains("find")
        || name.contains("search")
        || name.contains("overlay")
        || name.contains("ghostty")
        || name.contains("wk")

    let isFocusRelated: Bool
    if let focusView {
        isFocusRelated = view === focusView
            || view.isDescendant(of: focusView)
            || focusView.isDescendant(of: view)
    } else {
        isFocusRelated = false
    }

    return looksFindRelated || isFocusRelated
}

private func describeResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    if let view = responder as? NSView {
        return describeView(view)
    }
    return String(describing: type(of: responder))
}

private func describeView(_ view: NSView) -> String {
    let className = String(describing: type(of: view))
    let frame = NSStringFromRect(view.frame)
    let bounds = NSStringFromRect(view.bounds)
    let hidden = view.isHidden ? "1" : "0"
    let alpha = String(format: "%.2f", view.alphaValue)
    let zPosition = view.layer.map { String(format: "%.1f", $0.zPosition) } ?? "nil"
    return "\(className) frame=\(frame) bounds=\(bounds) hidden=\(hidden) alpha=\(alpha) z=\(zPosition) subviews=\(view.subviews.count)"
}
