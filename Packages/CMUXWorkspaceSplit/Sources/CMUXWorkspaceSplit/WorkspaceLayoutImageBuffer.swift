import AppKit
import Foundation
import UniformTypeIdentifiers

struct WorkspaceLayoutRGBAImageBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

func workspaceLayoutRGBAImageBuffer(from image: NSImage) -> WorkspaceLayoutRGBAImageBuffer? {
    guard let cgImage = workspaceLayoutCGImage(from: image) else { return nil }
    return workspaceLayoutRGBAImageBuffer(from: cgImage)
}

func workspaceLayoutRGBAImageBuffer(from cgImage: CGImage) -> WorkspaceLayoutRGBAImageBuffer? {
    let width = cgImage.width
    let height = cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        return nil
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return WorkspaceLayoutRGBAImageBuffer(width: width, height: height, bytes: bytes)
}

func workspaceLayoutResizeImageBuffer(
    _ buffer: WorkspaceLayoutRGBAImageBuffer,
    width: Int,
    height: Int
) -> WorkspaceLayoutRGBAImageBuffer? {
    guard let image = workspaceLayoutImageFromRGBABytes(buffer.bytes, width: buffer.width, height: buffer.height),
          let cgImage = workspaceLayoutCGImage(from: image) else {
        return nil
    }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        return nil
    }
    context.interpolationQuality = .none
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return WorkspaceLayoutRGBAImageBuffer(width: width, height: height, bytes: bytes)
}

func workspaceLayoutImageFromRGBABytes(
    _ bytes: [UInt8],
    width: Int,
    height: Int
) -> NSImage? {
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData),
          let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
        return nil
    }
    let image = NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    return image
}

func workspaceLayoutCGImage(from image: NSImage) -> CGImage? {
    var proposed = CGRect(origin: .zero, size: image.size)
    if let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
        return cgImage
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return rep.cgImage
}

func workspaceLayoutWritePNG(image: NSImage, to url: URL) throws {
    guard let cgImage = workspaceLayoutCGImage(from: image) else {
        throw NSError(domain: "WorkspaceTabChromeDebug", code: 1, userInfo: nil)
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "WorkspaceTabChromeDebug", code: 2, userInfo: nil)
    }
    try data.write(to: url, options: .atomic)
}

func workspaceSplitSnapshotImage(
    for view: NSView,
    scale: CGFloat = 1,
    backgroundColor: NSColor? = nil
) -> NSImage? {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
    let width = max(1, Int(ceil(view.bounds.width * scale)))
    let height = max(1, Int(ceil(view.bounds.height * scale)))
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    rep.size = view.bounds.size
    if let backgroundColor,
       let context = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        backgroundColor.setFill()
        NSBezierPath(rect: view.bounds).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(rep)
    return image
}

func workspaceSplitDecodeTransfer(from pasteboard: NSPasteboard) -> TabTransferData? {
    let type = NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)
    if let data = pasteboard.data(forType: type),
       let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
        return transfer
    }
    if let raw = pasteboard.string(forType: type),
       let data = raw.data(using: .utf8),
       let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
        return transfer
    }
    return nil
}

func workspaceSplitHoveredTabBackground(
    for appearance: WorkspaceLayoutConfiguration.Appearance
) -> NSColor {
    guard let backgroundHex = appearance.chromeColors.backgroundHex,
          let custom = NSColor(workspaceSplitHex: backgroundHex) else {
        return NSColor.controlBackgroundColor.withAlphaComponent(0.5)
    }

    let adjusted = workspaceSplitIsLightColor(custom)
        ? workspaceSplitAdjustColor(custom, by: -0.03)
        : workspaceSplitAdjustColor(custom, by: 0.07)
    return adjusted.withAlphaComponent(0.78)
}

func workspaceSplitPressedTabBackground(
    for appearance: WorkspaceLayoutConfiguration.Appearance
) -> NSColor {
    guard let backgroundHex = appearance.chromeColors.backgroundHex,
          let custom = NSColor(workspaceSplitHex: backgroundHex) else {
        return NSColor.controlBackgroundColor.withAlphaComponent(0.72)
    }

    let adjusted = workspaceSplitIsLightColor(custom)
        ? workspaceSplitAdjustColor(custom, by: -0.065)
        : workspaceSplitAdjustColor(custom, by: 0.12)
    return adjusted.withAlphaComponent(0.9)
}

func workspaceSplitIsLightColor(_ color: NSColor) -> Bool {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
    let luminance = (0.299 * rgb.redComponent) + (0.587 * rgb.greenComponent) + (0.114 * rgb.blueComponent)
    return luminance > 0.6
}

func workspaceSplitAdjustColor(_ color: NSColor, by delta: CGFloat) -> NSColor {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
    let clamp: (CGFloat) -> CGFloat = { min(max($0, 0), 1) }
    return NSColor(
        red: clamp(rgb.redComponent + delta),
        green: clamp(rgb.greenComponent + delta),
        blue: clamp(rgb.blueComponent + delta),
        alpha: rgb.alphaComponent
    )
}
