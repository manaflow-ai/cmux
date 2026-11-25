import CCmuxLaunchRecordFFI
public import Foundation

/// C values exist only for the duration of the synchronous Rust call. This is
/// called on the files lane; no pointer crosses an actor or task boundary.
public nonisolated struct LaunchRecordEncoding {
    public nonisolated init() {}
    public static func write(_ value: LaunchRecordSnapshot, to url: URL) -> Bool {
        guard !url.path.utf8.contains(0), !value.sessionSocketPath.utf8.contains(0) else { return false }
        let arena = LaunchRecordStrings()
        let windows = value.windows.compactMap { window -> CmuxLaunchWindowInput? in
            guard let tabCount = UInt(exactly: window.tabIDs.count) else { return nil }
            var input = CmuxLaunchWindowInput()
            input.frame_x = window.frame.origin.x; input.frame_y = window.frame.origin.y
            input.frame_width = window.frame.width; input.frame_height = window.frame.height
            input.display_id = window.displayID
            input.background_rgba = window.backgroundRGBA; input.bar_rgba = window.barRGBA
            input.image_pixel_width = window.imagePixelSize.width; input.image_pixel_height = window.imagePixelSize.height
            input.window_id = arena.put(window.id); input.image_key = arena.put(window.imageKey)
            input.visible_workspace_id = arena.put(window.workspaceID)
            input.visible_tab_ids = arena.put(window.tabIDs); input.visible_tab_count = tabCount
            input.backing_scale = window.backingScale
            input.screen_frame_x = window.screenFrame.origin.x; input.screen_frame_y = window.screenFrame.origin.y
            input.screen_frame_width = window.screenFrame.width; input.screen_frame_height = window.screenFrame.height
            input.appearance = window.appearance
            input.appearance_follows_system = window.appearanceFollowsSystem ? 1 : 0
            input.fullscreen = window.fullscreen ? 1 : 0
            return input
        }
        let sidebars = value.sidebarRows.map { row in
            CmuxLaunchSidebarInput(id: arena.put(row.id), title: arena.put(row.title), icon_key: arena.put(row.iconKey))
        }
        guard windows.count == value.windows.count, arena.valid,
              let windowCount = UInt(exactly: windows.count),
              let sidebarCount = UInt(exactly: sidebars.count) else { return false }
        // withExtendedLifetime keeps every C string and pointer array alive through Rust's borrow.
        return withExtendedLifetime(arena) {
            url.path.withCString { path in
                value.sessionSocketPath.withCString { socket in
                    windows.withUnsafeBufferPointer { windows in
                        sidebars.withUnsafeBufferPointer { sidebars in
                            cmux_launch_record_write(path, windows.baseAddress, windowCount,
                                                     sidebars.baseAddress, sidebarCount, socket)
                        }
                    }
                }
            }
        }
    }
}

private nonisolated final class LaunchRecordStrings {
    private(set) var valid = true
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var arrays: [(UnsafeMutablePointer<UnsafePointer<CChar>?>, Int)] = []

    deinit {
        for pointer in strings { pointer.deallocate() }
        for (pointer, count) in arrays { pointer.deinitialize(count: count); pointer.deallocate() }
    }

    func put(_ value: String) -> UnsafePointer<CChar> {
        if value.utf8.contains(0) { valid = false }
        let bytes = value.utf8CString
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        bytes.withUnsafeBufferPointer { bytes in
            if let base = bytes.baseAddress { pointer.initialize(from: base, count: bytes.count) }
        }
        strings.append(pointer)
        return UnsafePointer(pointer)
    }

    func put(_ values: [String]) -> UnsafePointer<UnsafePointer<CChar>?>? {
        guard !values.isEmpty else { return nil }
        let pointer = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: values.count)
        for (index, value) in values.enumerated() { pointer.advanced(by: index).initialize(to: put(value)) }
        arrays.append((pointer, values.count))
        return UnsafePointer(pointer)
    }
}
