#if os(iOS)
import UIKit

@MainActor
struct WorkspaceListDragPreviewFactory {
    struct Metrics {
        let insets: UIEdgeInsets
        let cornerRadius: CGFloat
    }

    func parameters(
        for item: WorkspaceListTableItem,
        cell: UITableViewCell
    ) -> UIDragPreviewParameters? {
        guard let metrics = metrics(for: item) else { return nil }
        return parameters(
            bounds: cell.bounds.inset(by: metrics.insets),
            cornerRadius: metrics.cornerRadius
        )
    }

    func preview(
        for item: WorkspaceListTableItem,
        cell: UITableViewCell
    ) -> UIDragPreview? {
        guard let metrics = metrics(for: item) else { return nil }
        let previewRect = cell.bounds.inset(by: metrics.insets)
        let format = UIGraphicsImageRendererFormat()
        format.scale = cell.window?.screen.scale ?? UIScreen.main.scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: previewRect.size,
            format: format
        ).image { rendererContext in
            UIColor.systemBackground.setFill()
            rendererContext.fill(
                CGRect(origin: .zero, size: previewRect.size)
            )
            rendererContext.cgContext.translateBy(
                x: -previewRect.minX,
                y: -previewRect.minY
            )
            cell.layer.render(in: rendererContext.cgContext)
        }
        let imageView = UIImageView(image: image)
        imageView.frame = CGRect(origin: .zero, size: previewRect.size)
        imageView.backgroundColor = .systemBackground
        imageView.contentMode = .scaleToFill
        imageView.layer.cornerRadius = metrics.cornerRadius
        imageView.clipsToBounds = true

        return UIDragPreview(
            view: imageView,
            parameters: parameters(
                bounds: imageView.bounds,
                cornerRadius: metrics.cornerRadius
            )
        )
    }

    private func parameters(
        bounds: CGRect,
        cornerRadius: CGFloat
    ) -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .systemBackground
        parameters.visiblePath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: cornerRadius
        )
        return parameters
    }

    func metrics(
        for item: WorkspaceListTableItem
    ) -> Metrics? {
        switch item {
        case .workspace:
            Metrics(
                insets: UIEdgeInsets(
                    top: 4,
                    left: item.isIndentedWorkspace ? 32 : 12,
                    bottom: 4,
                    right: 12
                ),
                cornerRadius: 14
            )
        case .groupHeader:
            Metrics(
                insets: UIEdgeInsets(
                    top: 6,
                    left: 12,
                    bottom: 6,
                    right: 12
                ),
                cornerRadius: 6
            )
        case .chrome, .filterEmpty, .groupFooter:
            nil
        }
    }
}
#endif
