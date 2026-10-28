import AppKit
import CmuxNextFileGrid

/// A drop read off the drag's pasteboard while the drop is performed, saved after the drag ends.
struct ScreenshotDropValue: FileGridDropContents {
    let droppedFileURLs: [URL]
    let droppedImage: NSImage?
    var holdsImage: Bool { droppedImage != nil }
}
