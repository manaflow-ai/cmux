import CmuxNextDesign
import SwiftUI

/// One scene node, rendered natively. Containers recurse through
/// `AnyView` (the scene is data, so the view type cannot be static);
/// Group and ForEach children lay out inline in the parent stack.
struct AppSceneNodeView: View {
    @Environment(\.appSceneColors) private var colors
    let model: AppSceneModel
    let id: String

    var body: some View {
        if let node = model.scene[id] {
            content(node).modifier(AppSceneDecorations(model: model, id: id, node: node))
        }
    }

    @ViewBuilder
    private func content(_ node: AppSceneNode) -> some View {
        switch node.type {
        case .vStack, .group, .forEach, .reorderable:
            VStack(alignment: AppSceneStyle.alignment(node), spacing: node.number("spacing").map { CGFloat($0) } ?? 0) { children(node) }
        case .lazyVStack:
            LazyVStack(alignment: AppSceneStyle.alignment(node), spacing: node.number("spacing").map { CGFloat($0) } ?? 0) { children(node) }
        case .hStack:
            HStack(spacing: node.number("spacing").map { CGFloat($0) } ?? Metrics.space2) { children(node) }
        case .zStack:
            ZStack { children(node) }
        case .text:
            Text(node.string("text") ?? "")
                .font(AppSceneStyle.font(node))
                .foregroundStyle(colors.token(node.props["color"]) ?? colors.primary)
                .lineLimit(node.number("lineLimit").map { max(1, Int($0)) } ?? nil)
                .truncationMode(AppSceneStyle.truncation(node))
        case .icon:
            Image(systemName: node.string("symbol") ?? "circle")
                .font(.system(size: node.number("size").map { CGFloat($0) } ?? Metrics.smallIconSize - Metrics.space1))
                .foregroundStyle(colors.token(node.props["color"]) ?? colors.secondary)
        case .image:
            AppSceneBundleImage(path: node.string("src"))
        case .button:
            AppSceneButton(model: model, id: id, node: node) { AnyView(children(node)) }
        case .menu:
            AppSceneMenuButton(model: model, id: id, node: node)
        case .spacer:
            Spacer(minLength: 0)
        case .divider:
            Divider().overlay(colors.separator)
        case .circle, .capsule, .rectangle, .roundedRectangle:
            AppSceneShape(node: node)
        case .progressView:
            if let value = node.number("value") { ProgressView(value: min(max(value, 0), 1)).controlSize(.small) } else { ProgressView().controlSize(.small) }
        case .textField:
            AppSceneTextField(model: model, id: id, node: node)
        case .row:
            AppSceneRowView(node: node)
        case .badge:
            AppSceneBadge(text: node.string("text") ?? "", tone: node.props["tone"])
        case .emptyState:
            AppSceneEmptyState(node: node)
        }
    }

    private func children(_ node: AppSceneNode) -> some View {
        ForEach(model.scene.flattenedChildren(of: id), id: \.self) { child in
            AppSceneNodeView(model: model, id: child)
        }
    }
}

/// A Button node: its title, or its child views as the label.
struct AppSceneButton: View {
    @Environment(\.appSceneColors) private var colors
    let model: AppSceneModel
    let id: String
    let node: AppSceneNode
    let label: () -> AnyView

    var body: some View {
        Button {
            model.send(id, "tap")
        } label: {
            if let title = node.string("title") {
                Text(title).foregroundStyle(node.flag("destructive") ? colors.danger : colors.primary)
            } else {
                label()
            }
        }
        .buttonStyle(.plain)
    }
}

