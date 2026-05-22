import Foundation
import OwlMojoBindingsGenerated

enum OwlFreshSurfaceTreeWireCodec {
    static func readSurfaceTree(_ data: Data, at offset: Int) throws -> OwlFreshSurfaceTree {
        OwlFreshSurfaceTree(
            generation: try data.mojoUInt64(at: offset + 8),
            surfaces: try data.mojoStructPointerArray(pointerOffset: offset + 16) { surfaceOffset in
                try readSurfaceInfo(data, at: surfaceOffset)
            }
        )
    }

    static func surfaceTreeData(_ tree: OwlFreshSurfaceTree) -> Data {
        var data = Data(count: 24)
        data.writeUInt32(24, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(tree.generation, at: 8)
        data.appendMojoPointer(
            child: MojoWireMessage.structPointerArray(tree.surfaces.map(surfaceInfoData)),
            pointerOffset: 16
        )
        return data
    }

    private static func readSurfaceInfo(_ data: Data, at offset: Int) throws -> OwlFreshSurfaceInfo {
        let structSize = try data.mojoUInt32(at: offset)
        let kindRaw = UInt32(bitPattern: try data.mojoInt32(at: offset + 24))
        guard let kind = OwlFreshSurfaceKind(rawValue: kindRaw) else {
            throw MojoWireDataError.invalidResponse("unknown surface kind \(kindRaw)")
        }
        let flags = try data.mojoUInt8(at: offset + 56)
        return OwlFreshSurfaceInfo(
            surfaceId: try data.mojoUInt64(at: offset + 8),
            parentSurfaceId: try data.mojoUInt64(at: offset + 16),
            kind: kind,
            contextId: try data.mojoUInt32(at: offset + 28),
            x: try data.mojoInt32(at: offset + 32),
            y: try data.mojoInt32(at: offset + 36),
            width: try data.mojoUInt32(at: offset + 40),
            height: try data.mojoUInt32(at: offset + 44),
            scale: try data.mojoFloat32(at: offset + 48),
            zIndex: try data.mojoInt32(at: offset + 52),
            visible: flags & (1 << 0) != 0,
            menuItems: try data.mojoStringArray(pointerOffset: offset + 64),
            nativeMenuItems: try data.mojoStructPointerArray(pointerOffset: offset + 72) { itemOffset in
                try readNativeMenuItem(data, at: itemOffset)
            },
            selectedIndex: try data.mojoInt32(at: offset + 60),
            itemFontSize: try data.mojoFloat32(at: offset + 80),
            rightAligned: flags & (1 << 1) != 0,
            filePickerMode: try data.mojoString(pointerOffset: offset + 88),
            filePickerAcceptTypes: try data.mojoStringArray(pointerOffset: offset + 96),
            filePickerAllowsMultiple: flags & (1 << 2) != 0,
            filePickerUploadFolder: flags & (1 << 3) != 0,
            label: try data.mojoString(pointerOffset: offset + 104),
            promptTitle: structSize >= 120 ? try data.mojoString(pointerOffset: offset + 112) : "",
            promptMessage: structSize >= 128 ? try data.mojoString(pointerOffset: offset + 120) : "",
            promptPrimaryButton: structSize >= 136 ? try data.mojoString(pointerOffset: offset + 128) : "",
            promptSecondaryButton: structSize >= 144 ? try data.mojoString(pointerOffset: offset + 136) : "",
            promptDefaultUsername: structSize >= 152 ? try data.mojoString(pointerOffset: offset + 144) : "",
            promptOrigin: structSize >= 160 ? try data.mojoString(pointerOffset: offset + 152) : ""
        )
    }

    private static func surfaceInfoData(_ surface: OwlFreshSurfaceInfo) -> Data {
        var data = Data(count: 160)
        data.writeUInt32(160, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(surface.surfaceId, at: 8)
        data.writeUInt64(surface.parentSurfaceId, at: 16)
        data.writeInt32(Int32(bitPattern: surface.kind.rawValue), at: 24)
        data.writeUInt32(surface.contextId, at: 28)
        data.writeInt32(surface.x, at: 32)
        data.writeInt32(surface.y, at: 36)
        data.writeUInt32(surface.width, at: 40)
        data.writeUInt32(surface.height, at: 44)
        data.writeFloat32(surface.scale, at: 48)
        data.writeInt32(surface.zIndex, at: 52)
        var flags: UInt8 = 0
        if surface.visible { flags |= 1 << 0 }
        if surface.rightAligned { flags |= 1 << 1 }
        if surface.filePickerAllowsMultiple { flags |= 1 << 2 }
        if surface.filePickerUploadFolder { flags |= 1 << 3 }
        data[56] = flags
        data.writeInt32(surface.selectedIndex, at: 60)
        data.appendMojoPointer(child: MojoWireMessage.stringArray(surface.menuItems), pointerOffset: 64)
        data.appendMojoPointer(
            child: MojoWireMessage.structPointerArray(surface.nativeMenuItems.map(nativeMenuItemData)),
            pointerOffset: 72
        )
        data.writeFloat32(surface.itemFontSize, at: 80)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(surface.filePickerMode), pointerOffset: 88)
        data.appendMojoPointer(child: MojoWireMessage.stringArray(surface.filePickerAcceptTypes), pointerOffset: 96)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(surface.label), pointerOffset: 104)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(surface.promptTitle), pointerOffset: 112)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(surface.promptMessage), pointerOffset: 120)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(surface.promptPrimaryButton), pointerOffset: 128)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(surface.promptSecondaryButton), pointerOffset: 136)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(surface.promptDefaultUsername), pointerOffset: 144)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(surface.promptOrigin), pointerOffset: 152)
        return data
    }

    private static func readNativeMenuItem(_ data: Data, at offset: Int) throws -> OwlFreshNativeMenuItem {
        let flags = try data.mojoUInt8(at: offset + 24)
        return OwlFreshNativeMenuItem(
            label: try data.mojoString(pointerOffset: offset + 8),
            toolTip: try data.mojoString(pointerOffset: offset + 16),
            enabled: flags & (1 << 0) != 0,
            separator: flags & (1 << 1) != 0,
            group: flags & (1 << 2) != 0,
            textDirection: try data.mojoUInt32(at: offset + 28),
            hasTextDirectionOverride: flags & (1 << 3) != 0
        )
    }

    private static func nativeMenuItemData(_ item: OwlFreshNativeMenuItem) -> Data {
        var data = Data(count: 32)
        data.writeUInt32(32, at: 0)
        data.writeUInt32(0, at: 4)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(item.label), pointerOffset: 8)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(item.toolTip), pointerOffset: 16)
        var flags: UInt8 = 0
        if item.enabled { flags |= 1 << 0 }
        if item.separator { flags |= 1 << 1 }
        if item.group { flags |= 1 << 2 }
        if item.hasTextDirectionOverride { flags |= 1 << 3 }
        data[24] = flags
        data.writeUInt32(item.textDirection, at: 28)
        return data
    }
}
