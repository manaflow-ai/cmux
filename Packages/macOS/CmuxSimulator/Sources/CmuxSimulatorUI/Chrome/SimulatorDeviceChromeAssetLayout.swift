import Foundation

struct SimulatorDeviceChromeAssetLayout {
    let body: CGRect
    let imageSizes: [String: CGSize]

    func rect(for name: String) -> CGRect? {
        guard let size = imageSizes[name], size.width > 0, size.height > 0 else { return nil }
        switch name {
        case "topLeft":
            return CGRect(x: body.minX, y: body.maxY - size.height, width: size.width, height: size.height)
        case "top":
            return CGRect(
                x: body.minX + leftCap,
                y: body.maxY - size.height,
                width: max(body.width - leftCap - rightCap, 0),
                height: size.height
            )
        case "topRight":
            return CGRect(x: body.maxX - size.width, y: body.maxY - size.height, width: size.width, height: size.height)
        case "right":
            return CGRect(
                x: body.maxX - size.width,
                y: body.minY + bottomCap,
                width: size.width,
                height: max(body.height - topCap - bottomCap, 0)
            )
        case "bottomRight":
            return CGRect(x: body.maxX - size.width, y: body.minY, width: size.width, height: size.height)
        case "bottom":
            return CGRect(
                x: body.minX + leftCap,
                y: body.minY,
                width: max(body.width - leftCap - rightCap, 0),
                height: size.height
            )
        case "bottomLeft":
            return CGRect(x: body.minX, y: body.minY, width: size.width, height: size.height)
        case "left":
            return CGRect(
                x: body.minX,
                y: body.minY + bottomCap,
                width: size.width,
                height: max(body.height - topCap - bottomCap, 0)
            )
        default:
            return nil
        }
    }

    private var leftCap: CGFloat {
        max(imageSizes["topLeft"]?.width ?? 0, imageSizes["bottomLeft"]?.width ?? 0)
    }

    private var rightCap: CGFloat {
        max(imageSizes["topRight"]?.width ?? 0, imageSizes["bottomRight"]?.width ?? 0)
    }

    private var topCap: CGFloat {
        max(imageSizes["topLeft"]?.height ?? 0, imageSizes["topRight"]?.height ?? 0)
    }

    private var bottomCap: CGFloat {
        max(imageSizes["bottomLeft"]?.height ?? 0, imageSizes["bottomRight"]?.height ?? 0)
    }
}
