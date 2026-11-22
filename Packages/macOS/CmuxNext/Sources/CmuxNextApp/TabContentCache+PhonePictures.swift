import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextMobileHost

/// Browser tabs' thumbnails and favicons for the phones' tab overview (`tabs`): the leave picture a page already
/// takes (`finishPageCapture`) and each favicon the page shows go to ``PhoneTabPictures``, keyed by the tab's
/// surface on this Mac's own daemon (the id hostd's `tabs` rows use). A tab of another machine or an incognito
/// page sends nothing. Nothing is captured for the phone alone.
extension TabContentCache {
    /// The widest thumbnail a phone gets.
    static let phoneThumbnailWidth: CGFloat = 576

    /// The surface the phones know tab `key` by: a tab of this Mac's daemon showing a page that is not incognito.
    func phoneSurface(_ key: String, page: any BrowserTab) -> UInt64? {
        guard phonePictures?.wanted == true, !cef.stores.offTheRecord.isOffTheRecord(page.profileID),
              let tab = tabModel(key), browserTabs.daemon(for: tab).isLocal else { return nil }
        return tab.surface.rawValue
    }

    /// A leave picture of `key`'s page, cut to ``phoneThumbnailWidth`` and encoded off the main actor.
    func offerPhoneThumbnail(_ image: CGImage, key: String) {
        guard let pictures = phonePictures, let page = browsers[key]?.tab, let surface = phoneSurface(key, page: page) else { return }
        phoneSurfaces[key] = surface
        let width = Self.phoneThumbnailWidth
        // task-owner: one encode per leave picture; ends on its own.
        Task {
            let encoded = await Task.detached(priority: .utility) { () -> (data: Data, width: Int, height: Int)? in
                let cut = PreviewImageCache.fitted(image, CGSize(width: width, height: .greatestFiniteMagnitude))
                return PreviewImageCache.compressed(cut, quality: 0.7).map { ($0.data, cut.width, cut.height) }
            }.value
            guard let encoded else { return }
            pictures.offer(surface: surface, part: .thumb, data: encoded.data, width: encoded.width, height: encoded.height)
        }
    }

    /// Follows `page`'s favicon for the phones while it is `key`'s page (stopped when it leaves `browsers`).
    func followPhoneFavicon(_ page: any BrowserTab, key: String) {
        phoneFavicons.removeValue(forKey: key)?.cancel()
        guard phonePictures != nil else { return }
        // task-owner: phoneFavicons[key]; event-driven (Observation), cancelled when the page leaves `browsers`.
        phoneFavicons[key] = Task { [weak self, weak page] in
            let icons = ObservationStream { [weak page] () -> ObjectIdentifier? in page?.favicon.map(ObjectIdentifier.init) }
            for await icon in icons {
                guard icon != nil, let self, let page, let favicon = page.favicon,
                      let pictures = self.phonePictures, let surface = self.phoneSurface(key, page: page),
                      let cgImage = favicon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                self.phoneSurfaces[key] = surface
                let png = await Task.detached(priority: .utility) {
                    NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
                }.value
                guard !Task.isCancelled, let png else { continue }
                pictures.offer(surface: surface, part: .favicon, data: png, width: cgImage.width, height: cgImage.height)
            }
        }
    }

    /// Tab `key` closed: its pictures leave the phones' cache folder and the host's replay.
    func forgetPhonePictures(_ key: String) {
        guard let surface = phoneSurfaces.removeValue(forKey: key) else { return }
        phonePictures?.forget(surface: surface)
    }
}
