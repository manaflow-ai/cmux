import CoreGraphics

enum DesktopRenderMode: String, CaseIterable, Identifiable {
    case video
    case native

    var id: String {
        rawValue
    }
}

struct NativeWindowSlotFrame: Equatable {
    var quartzFrame: CGRect
    var cocoaFrame: CGRect
}
