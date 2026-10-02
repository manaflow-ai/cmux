#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Fetches and decodes attachment images off the main thread, sized for display.
@MainActor
final class ConversationImageLoader {
    static let shared = ConversationImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        return URLSession(configuration: configuration)
    }()

    init() {
        cache.totalCostLimit = 48 << 20
    }

    func cachedImage(for attachment: ConversationAttachment, pixelWidth: CGFloat) -> UIImage? {
        cache.object(forKey: key(attachment, pixelWidth) as NSString)
    }

    func image(for attachment: ConversationAttachment, pixelWidth: CGFloat) async -> UIImage? {
        let key = key(attachment, pixelWidth)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }
        let session = session
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            let data: Data?
            if let local = attachment.localData {
                data = local
            } else if let url = attachment.url {
                data = try? await session.data(from: url).0
            } else {
                data = nil
            }
            guard let data, let image = UIImage(data: data) else { return nil }
            let scale = pixelWidth / max(image.size.width * image.scale, 1)
            let target = CGSize(width: image.size.width * min(1, scale), height: image.size.height * min(1, scale))
            return await image.byPreparingThumbnail(ofSize: target) ?? image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    private func key(_ attachment: ConversationAttachment, _ pixelWidth: CGFloat) -> String {
        "\(attachment.id)@\(Int(pixelWidth))"
    }
}
#endif
