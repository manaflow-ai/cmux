import AppKit
import Foundation
// usage: imgsig IMAGE Y0 Y1  -> 32x64 grayscale signature (hex) of the rows Y0..Y1 (points,
// 3x screenshot) of IMAGE: the streamed page area without the status bar's clock.
let args = CommandLine.arguments
guard args.count >= 4, let img = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let y0 = Int(Double(args[2])! * 3), y1 = min(cg.height, Int(Double(args[3])! * 3))
guard let crop = cg.cropping(to: CGRect(x: 0, y: y0, width: cg.width, height: max(1, y1 - y0))) else { exit(2) }
let w = 32, h = 64
var px = [UInt8](repeating: 0, count: w * h)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
ctx.interpolationQuality = .medium
ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
print(px.map { String(format: "%02x", $0) }.joined())
