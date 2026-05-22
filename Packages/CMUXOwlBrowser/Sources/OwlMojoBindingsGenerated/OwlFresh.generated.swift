// Generated from Mojo/OwlFresh.mojom by OwlMojoBindingsGenerator.
// Do not edit by hand.
import Foundation

public struct MojoPendingRemote<Interface>: Equatable, Codable, Sendable {
    public let handle: UInt64

    public init(handle: UInt64) {
        self.handle = handle
    }
}

public struct MojoPendingReceiver<Interface>: Equatable, Codable, Sendable {
    public let handle: UInt64

    public init(handle: UInt64) {
        self.handle = handle
    }
}

public final class OwlFreshMojoPipeHandleAllocator {
    private var nextHandle: UInt64

    public init(startingAt firstHandle: UInt64 = 1) {
        self.nextHandle = firstHandle
    }

    public func makeRemote<Interface>(_ interface: Interface.Type = Interface.self) -> MojoPendingRemote<Interface> {
        MojoPendingRemote(handle: allocate())
    }

    public func makeReceiver<Interface>(_ interface: Interface.Type = Interface.self) -> MojoPendingReceiver<Interface> {
        MojoPendingReceiver(handle: allocate())
    }

    private func allocate() -> UInt64 {
        let handle = nextHandle
        nextHandle += 1
        return handle
    }
}

public struct OwlFreshMojoTransportCall: Equatable, Codable, Sendable {
    public let interface: String
    public let method: String
    public let payloadType: String
    public let payloadSummary: String

    public init(interface: String, method: String, payloadType: String, payloadSummary: String) {
        self.interface = interface
        self.method = method
        self.payloadType = payloadType
        self.payloadSummary = payloadSummary
    }
}

public final class OwlFreshMojoTransportRecorder {
    public private(set) var recordedCalls: [OwlFreshMojoTransportCall] = []

    public init() {}

    public func record(interface: String, method: String, payloadType: String, payloadSummary: String) {
        recordedCalls.append(OwlFreshMojoTransportCall(
            interface: interface,
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        ))
    }

    public func reset() {
        recordedCalls.removeAll()
    }
}

public enum OwlFreshGeneratedMojoTransport {
    public static let name = "GeneratedOwlFreshMojoTransport"
}

private enum MojoJSONCoding {
    static func decodeUInt8<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> UInt8 {
        if let value = try? container.decode(UInt8.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            if value >= 0, value <= Int64(UInt8.max) {
                return UInt8(value)
            }
            guard let signed = Int8(exactly: value) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "signed value cannot wrap to UInt8")
            }
            return UInt8(bitPattern: signed)
        }
        if let value = try? container.decode(String.self, forKey: key), let parsed = UInt8(value) {
            return parsed
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "expected UInt8-compatible value")
    }

    static func decodeUInt32<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> UInt32 {
        if let value = try? container.decode(UInt32.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            if value >= 0, value <= Int64(UInt32.max) {
                return UInt32(value)
            }
            guard let signed = Int32(exactly: value) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "signed value cannot wrap to UInt32")
            }
            return UInt32(bitPattern: signed)
        }
        if let value = try? container.decode(String.self, forKey: key), let parsed = UInt32(value) {
            return parsed
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "expected UInt32-compatible value")
    }

    static func decodeUInt64<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> UInt64 {
        if let value = try? container.decode(UInt64.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            if value >= 0 {
                return UInt64(value)
            }
            return UInt64(bitPattern: value)
        }
        if let value = try? container.decode(String.self, forKey: key), let parsed = UInt64(value) {
            return parsed
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "expected UInt64-compatible value")
    }
}

public enum OwlFreshMouseKind: UInt32, Codable, CaseIterable, Sendable {
    case down = 0
    case up = 1
    case move = 2
    case wheel = 3
}

public struct OwlFreshMouseEvent: Equatable, Codable, Sendable {
    public let kind: OwlFreshMouseKind
    public let x: Float
    public let y: Float
    public let button: UInt32
    public let clickCount: UInt32
    public let deltaX: Float
    public let deltaY: Float
    public let modifiers: UInt32

    public init(kind: OwlFreshMouseKind, x: Float, y: Float, button: UInt32, clickCount: UInt32, deltaX: Float, deltaY: Float, modifiers: UInt32) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.modifiers = modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(OwlFreshMouseKind.self, forKey: .kind)
        self.x = try container.decode(Float.self, forKey: .x)
        self.y = try container.decode(Float.self, forKey: .y)
        self.button = try MojoJSONCoding.decodeUInt32(from: container, forKey: .button)
        self.clickCount = try MojoJSONCoding.decodeUInt32(from: container, forKey: .clickCount)
        self.deltaX = try container.decode(Float.self, forKey: .deltaX)
        self.deltaY = try container.decode(Float.self, forKey: .deltaY)
        self.modifiers = try MojoJSONCoding.decodeUInt32(from: container, forKey: .modifiers)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(button, forKey: .button)
        try container.encode(clickCount, forKey: .clickCount)
        try container.encode(deltaX, forKey: .deltaX)
        try container.encode(deltaY, forKey: .deltaY)
        try container.encode(modifiers, forKey: .modifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case x
        case y
        case button
        case clickCount
        case deltaX
        case deltaY
        case modifiers
    }
}

public struct OwlFreshWheelEvent: Equatable, Codable, Sendable {
    public let x: Float
    public let y: Float
    public let deltaX: Float
    public let deltaY: Float
    public let wheelTicksX: Float
    public let wheelTicksY: Float
    public let phase: UInt32
    public let momentumPhase: UInt32
    public let modifiers: UInt32
    public let deltaUnits: UInt32

    public init(x: Float, y: Float, deltaX: Float, deltaY: Float, wheelTicksX: Float, wheelTicksY: Float, phase: UInt32, momentumPhase: UInt32, modifiers: UInt32, deltaUnits: UInt32) {
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.wheelTicksX = wheelTicksX
        self.wheelTicksY = wheelTicksY
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.modifiers = modifiers
        self.deltaUnits = deltaUnits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try container.decode(Float.self, forKey: .x)
        self.y = try container.decode(Float.self, forKey: .y)
        self.deltaX = try container.decode(Float.self, forKey: .deltaX)
        self.deltaY = try container.decode(Float.self, forKey: .deltaY)
        self.wheelTicksX = try container.decode(Float.self, forKey: .wheelTicksX)
        self.wheelTicksY = try container.decode(Float.self, forKey: .wheelTicksY)
        self.phase = try MojoJSONCoding.decodeUInt32(from: container, forKey: .phase)
        self.momentumPhase = try MojoJSONCoding.decodeUInt32(from: container, forKey: .momentumPhase)
        self.modifiers = try MojoJSONCoding.decodeUInt32(from: container, forKey: .modifiers)
        self.deltaUnits = try MojoJSONCoding.decodeUInt32(from: container, forKey: .deltaUnits)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(deltaX, forKey: .deltaX)
        try container.encode(deltaY, forKey: .deltaY)
        try container.encode(wheelTicksX, forKey: .wheelTicksX)
        try container.encode(wheelTicksY, forKey: .wheelTicksY)
        try container.encode(phase, forKey: .phase)
        try container.encode(momentumPhase, forKey: .momentumPhase)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(deltaUnits, forKey: .deltaUnits)
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case deltaX
        case deltaY
        case wheelTicksX
        case wheelTicksY
        case phase
        case momentumPhase
        case modifiers
        case deltaUnits
    }
}

public struct OwlFreshKeyEvent: Equatable, Codable, Sendable {
    public let keyDown: Bool
    public let keyCode: UInt32
    public let text: String
    public let modifiers: UInt32
    public let editCommands: [String]
    public let nativeEventType: UInt32
    public let nativeKeyCode: UInt32
    public let isRepeat: Bool
    public let characters: String
    public let charactersIgnoringModifiers: String

    public init(
        keyDown: Bool,
        keyCode: UInt32,
        text: String,
        modifiers: UInt32,
        editCommands: [String] = [],
        nativeEventType: UInt32 = 0,
        nativeKeyCode: UInt32 = 0,
        isRepeat: Bool = false,
        characters: String = "",
        charactersIgnoringModifiers: String = ""
    ) {
        self.keyDown = keyDown
        self.keyCode = keyCode
        self.text = text
        self.modifiers = modifiers
        self.editCommands = editCommands
        self.nativeEventType = nativeEventType
        self.nativeKeyCode = nativeKeyCode
        self.isRepeat = isRepeat
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.keyDown = try container.decode(Bool.self, forKey: .keyDown)
        self.keyCode = try MojoJSONCoding.decodeUInt32(from: container, forKey: .keyCode)
        self.text = try container.decode(String.self, forKey: .text)
        self.modifiers = try MojoJSONCoding.decodeUInt32(from: container, forKey: .modifiers)
        self.editCommands = try container.decodeIfPresent([String].self, forKey: .editCommands) ?? []
        self.nativeEventType = try container.contains(.nativeEventType) ? MojoJSONCoding.decodeUInt32(from: container, forKey: .nativeEventType) : 0
        self.nativeKeyCode = try container.contains(.nativeKeyCode) ? MojoJSONCoding.decodeUInt32(from: container, forKey: .nativeKeyCode) : 0
        self.isRepeat = try container.decodeIfPresent(Bool.self, forKey: .isRepeat) ?? false
        self.characters = try container.decodeIfPresent(String.self, forKey: .characters) ?? ""
        self.charactersIgnoringModifiers = try container.decodeIfPresent(String.self, forKey: .charactersIgnoringModifiers) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyDown, forKey: .keyDown)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(text, forKey: .text)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(editCommands, forKey: .editCommands)
        try container.encode(nativeEventType, forKey: .nativeEventType)
        try container.encode(nativeKeyCode, forKey: .nativeKeyCode)
        try container.encode(isRepeat, forKey: .isRepeat)
        try container.encode(characters, forKey: .characters)
        try container.encode(charactersIgnoringModifiers, forKey: .charactersIgnoringModifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case keyDown
        case keyCode
        case text
        case modifiers
        case editCommands
        case nativeEventType
        case nativeKeyCode
        case isRepeat
        case characters
        case charactersIgnoringModifiers
    }
}

public enum OwlFreshCompositionKind: UInt32, Codable, CaseIterable, Sendable {
    case set = 0
    case commit = 1
    case finish = 2
}

public struct OwlFreshCompositionEvent: Equatable, Codable, Sendable {
    public let kind: OwlFreshCompositionKind
    public let text: String
    public let selectionStart: UInt32
    public let selectionEnd: UInt32
    public let keepSelection: Bool

    public init(
        kind: OwlFreshCompositionKind,
        text: String,
        selectionStart: UInt32 = 0,
        selectionEnd: UInt32 = 0,
        keepSelection: Bool = false
    ) {
        self.kind = kind
        self.text = text
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
        self.keepSelection = keepSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(OwlFreshCompositionKind.self, forKey: .kind)
        self.text = try container.decode(String.self, forKey: .text)
        self.selectionStart = try container.contains(.selectionStart) ? MojoJSONCoding.decodeUInt32(from: container, forKey: .selectionStart) : 0
        self.selectionEnd = try container.contains(.selectionEnd) ? MojoJSONCoding.decodeUInt32(from: container, forKey: .selectionEnd) : 0
        self.keepSelection = try container.decodeIfPresent(Bool.self, forKey: .keepSelection) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(selectionStart, forKey: .selectionStart)
        try container.encode(selectionEnd, forKey: .selectionEnd)
        try container.encode(keepSelection, forKey: .keepSelection)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case selectionStart
        case selectionEnd
        case keepSelection
    }
}

public struct OwlFreshCompositorInfo: Equatable, Codable, Sendable {
    public let contextId: UInt32

    public init(contextId: UInt32) {
        self.contextId = contextId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.contextId = try MojoJSONCoding.decodeUInt32(from: container, forKey: .contextId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contextId, forKey: .contextId)
    }

    private enum CodingKeys: String, CodingKey {
        case contextId
    }
}

public enum OwlFreshSurfaceKind: UInt32, Codable, CaseIterable, Sendable {
    case webView = 0
    case popupWidget = 1
    case nativeMenu = 2
    case nativeFilePicker = 3
    case devTools = 4
    case nativePermissionPrompt = 5
    case nativeAuthPrompt = 6
}

public enum OwlFreshDevToolsMode: UInt32, Codable, CaseIterable, Sendable {
    case bottom = 0
    case right = 1
    case left = 2
    case window = 3
}

public struct OwlFreshNativeMenuItem: Equatable, Codable, Sendable {
    public let label: String
    public let toolTip: String
    public let enabled: Bool
    public let separator: Bool
    public let group: Bool
    public let textDirection: UInt32
    public let hasTextDirectionOverride: Bool

    public init(label: String, toolTip: String, enabled: Bool, separator: Bool, group: Bool, textDirection: UInt32, hasTextDirectionOverride: Bool) {
        self.label = label
        self.toolTip = toolTip
        self.enabled = enabled
        self.separator = separator
        self.group = group
        self.textDirection = textDirection
        self.hasTextDirectionOverride = hasTextDirectionOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decode(String.self, forKey: .label)
        self.toolTip = try container.decode(String.self, forKey: .toolTip)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.separator = try container.decode(Bool.self, forKey: .separator)
        self.group = try container.decode(Bool.self, forKey: .group)
        self.textDirection = try MojoJSONCoding.decodeUInt32(from: container, forKey: .textDirection)
        self.hasTextDirectionOverride = try container.decode(Bool.self, forKey: .hasTextDirectionOverride)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(toolTip, forKey: .toolTip)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(separator, forKey: .separator)
        try container.encode(group, forKey: .group)
        try container.encode(textDirection, forKey: .textDirection)
        try container.encode(hasTextDirectionOverride, forKey: .hasTextDirectionOverride)
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case toolTip
        case enabled
        case separator
        case group
        case textDirection
        case hasTextDirectionOverride
    }
}

public struct OwlFreshSurfaceInfo: Equatable, Codable, Sendable {
    public let surfaceId: UInt64
    public let parentSurfaceId: UInt64
    public let kind: OwlFreshSurfaceKind
    public let contextId: UInt32
    public let x: Int32
    public let y: Int32
    public let width: UInt32
    public let height: UInt32
    public let scale: Float
    public let zIndex: Int32
    public let visible: Bool
    public let menuItems: [String]
    public let nativeMenuItems: [OwlFreshNativeMenuItem]
    public let selectedIndex: Int32
    public let itemFontSize: Float
    public let rightAligned: Bool
    public let filePickerMode: String
    public let filePickerAcceptTypes: [String]
    public let filePickerAllowsMultiple: Bool
    public let filePickerUploadFolder: Bool
    public let label: String
    public let promptTitle: String
    public let promptMessage: String
    public let promptPrimaryButton: String
    public let promptSecondaryButton: String
    public let promptDefaultUsername: String
    public let promptOrigin: String

    public init(surfaceId: UInt64, parentSurfaceId: UInt64, kind: OwlFreshSurfaceKind, contextId: UInt32, x: Int32, y: Int32, width: UInt32, height: UInt32, scale: Float, zIndex: Int32, visible: Bool, menuItems: [String], nativeMenuItems: [OwlFreshNativeMenuItem], selectedIndex: Int32, itemFontSize: Float, rightAligned: Bool, filePickerMode: String, filePickerAcceptTypes: [String], filePickerAllowsMultiple: Bool, filePickerUploadFolder: Bool, label: String, promptTitle: String = "", promptMessage: String = "", promptPrimaryButton: String = "", promptSecondaryButton: String = "", promptDefaultUsername: String = "", promptOrigin: String = "") {
        self.surfaceId = surfaceId
        self.parentSurfaceId = parentSurfaceId
        self.kind = kind
        self.contextId = contextId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.scale = scale
        self.zIndex = zIndex
        self.visible = visible
        self.menuItems = menuItems
        self.nativeMenuItems = nativeMenuItems
        self.selectedIndex = selectedIndex
        self.itemFontSize = itemFontSize
        self.rightAligned = rightAligned
        self.filePickerMode = filePickerMode
        self.filePickerAcceptTypes = filePickerAcceptTypes
        self.filePickerAllowsMultiple = filePickerAllowsMultiple
        self.filePickerUploadFolder = filePickerUploadFolder
        self.label = label
        self.promptTitle = promptTitle
        self.promptMessage = promptMessage
        self.promptPrimaryButton = promptPrimaryButton
        self.promptSecondaryButton = promptSecondaryButton
        self.promptDefaultUsername = promptDefaultUsername
        self.promptOrigin = promptOrigin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.surfaceId = try MojoJSONCoding.decodeUInt64(from: container, forKey: .surfaceId)
        self.parentSurfaceId = try MojoJSONCoding.decodeUInt64(from: container, forKey: .parentSurfaceId)
        self.kind = try container.decode(OwlFreshSurfaceKind.self, forKey: .kind)
        self.contextId = try MojoJSONCoding.decodeUInt32(from: container, forKey: .contextId)
        self.x = try container.decode(Int32.self, forKey: .x)
        self.y = try container.decode(Int32.self, forKey: .y)
        self.width = try MojoJSONCoding.decodeUInt32(from: container, forKey: .width)
        self.height = try MojoJSONCoding.decodeUInt32(from: container, forKey: .height)
        self.scale = try container.decode(Float.self, forKey: .scale)
        self.zIndex = try container.decode(Int32.self, forKey: .zIndex)
        self.visible = try container.decode(Bool.self, forKey: .visible)
        self.menuItems = try container.decode([String].self, forKey: .menuItems)
        self.nativeMenuItems = try container.decode([OwlFreshNativeMenuItem].self, forKey: .nativeMenuItems)
        self.selectedIndex = try container.decode(Int32.self, forKey: .selectedIndex)
        self.itemFontSize = try container.decode(Float.self, forKey: .itemFontSize)
        self.rightAligned = try container.decode(Bool.self, forKey: .rightAligned)
        self.filePickerMode = try container.decode(String.self, forKey: .filePickerMode)
        self.filePickerAcceptTypes = try container.decode([String].self, forKey: .filePickerAcceptTypes)
        self.filePickerAllowsMultiple = try container.decode(Bool.self, forKey: .filePickerAllowsMultiple)
        self.filePickerUploadFolder = try container.decode(Bool.self, forKey: .filePickerUploadFolder)
        self.label = try container.decode(String.self, forKey: .label)
        self.promptTitle = try container.decodeIfPresent(String.self, forKey: .promptTitle) ?? ""
        self.promptMessage = try container.decodeIfPresent(String.self, forKey: .promptMessage) ?? ""
        self.promptPrimaryButton = try container.decodeIfPresent(String.self, forKey: .promptPrimaryButton) ?? ""
        self.promptSecondaryButton = try container.decodeIfPresent(String.self, forKey: .promptSecondaryButton) ?? ""
        self.promptDefaultUsername = try container.decodeIfPresent(String.self, forKey: .promptDefaultUsername) ?? ""
        self.promptOrigin = try container.decodeIfPresent(String.self, forKey: .promptOrigin) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(surfaceId, forKey: .surfaceId)
        try container.encode(parentSurfaceId, forKey: .parentSurfaceId)
        try container.encode(kind, forKey: .kind)
        try container.encode(contextId, forKey: .contextId)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(scale, forKey: .scale)
        try container.encode(zIndex, forKey: .zIndex)
        try container.encode(visible, forKey: .visible)
        try container.encode(menuItems, forKey: .menuItems)
        try container.encode(nativeMenuItems, forKey: .nativeMenuItems)
        try container.encode(selectedIndex, forKey: .selectedIndex)
        try container.encode(itemFontSize, forKey: .itemFontSize)
        try container.encode(rightAligned, forKey: .rightAligned)
        try container.encode(filePickerMode, forKey: .filePickerMode)
        try container.encode(filePickerAcceptTypes, forKey: .filePickerAcceptTypes)
        try container.encode(filePickerAllowsMultiple, forKey: .filePickerAllowsMultiple)
        try container.encode(filePickerUploadFolder, forKey: .filePickerUploadFolder)
        try container.encode(label, forKey: .label)
        try container.encode(promptTitle, forKey: .promptTitle)
        try container.encode(promptMessage, forKey: .promptMessage)
        try container.encode(promptPrimaryButton, forKey: .promptPrimaryButton)
        try container.encode(promptSecondaryButton, forKey: .promptSecondaryButton)
        try container.encode(promptDefaultUsername, forKey: .promptDefaultUsername)
        try container.encode(promptOrigin, forKey: .promptOrigin)
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceId
        case parentSurfaceId
        case kind
        case contextId
        case x
        case y
        case width
        case height
        case scale
        case zIndex
        case visible
        case menuItems
        case nativeMenuItems
        case selectedIndex
        case itemFontSize
        case rightAligned
        case filePickerMode
        case filePickerAcceptTypes
        case filePickerAllowsMultiple
        case filePickerUploadFolder
        case label
        case promptTitle
        case promptMessage
        case promptPrimaryButton
        case promptSecondaryButton
        case promptDefaultUsername
        case promptOrigin
    }
}

public struct OwlFreshSurfaceTree: Equatable, Codable, Sendable {
    public let generation: UInt64
    public let surfaces: [OwlFreshSurfaceInfo]

    public init(generation: UInt64, surfaces: [OwlFreshSurfaceInfo]) {
        self.generation = generation
        self.surfaces = surfaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generation = try MojoJSONCoding.decodeUInt64(from: container, forKey: .generation)
        self.surfaces = try container.decode([OwlFreshSurfaceInfo].self, forKey: .surfaces)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(surfaces, forKey: .surfaces)
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case surfaces
    }
}

public struct OwlFreshCaptureResult: Equatable, Codable, Sendable {
    public let png: [UInt8]
    public let width: UInt32
    public let height: UInt32
    public let captureMode: String
    public let error: String

    public init(png: [UInt8], width: UInt32, height: UInt32, captureMode: String, error: String) {
        self.png = png
        self.width = width
        self.height = height
        self.captureMode = captureMode
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.png = try container.decode([UInt8].self, forKey: .png)
        self.width = try MojoJSONCoding.decodeUInt32(from: container, forKey: .width)
        self.height = try MojoJSONCoding.decodeUInt32(from: container, forKey: .height)
        self.captureMode = try container.decode(String.self, forKey: .captureMode)
        self.error = try container.decode(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(png, forKey: .png)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(captureMode, forKey: .captureMode)
        try container.encode(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case png
        case width
        case height
        case captureMode
        case error
    }
}

public enum OwlFreshCursorType: Int32, Codable, CaseIterable, Sendable {
    case null = -1
    case pointer = 0
    case cross = 1
    case hand = 2
    case iBeam = 3
    case wait = 4
    case help = 5
    case eastResize = 6
    case northResize = 7
    case northEastResize = 8
    case northWestResize = 9
    case southResize = 10
    case southEastResize = 11
    case southWestResize = 12
    case westResize = 13
    case northSouthResize = 14
    case eastWestResize = 15
    case northEastSouthWestResize = 16
    case northWestSouthEastResize = 17
    case columnResize = 18
    case rowResize = 19
    case middlePanning = 20
    case eastPanning = 21
    case northPanning = 22
    case northEastPanning = 23
    case northWestPanning = 24
    case southPanning = 25
    case southEastPanning = 26
    case southWestPanning = 27
    case westPanning = 28
    case move = 29
    case verticalText = 30
    case cell = 31
    case contextMenu = 32
    case alias = 33
    case progress = 34
    case noDrop = 35
    case copy = 36
    case none = 37
    case notAllowed = 38
    case zoomIn = 39
    case zoomOut = 40
    case grab = 41
    case grabbing = 42
    case middlePanningVertical = 43
    case middlePanningHorizontal = 44
    case custom = 45
    case dndNone = 46
    case dndMove = 47
    case dndCopy = 48
    case dndLink = 49
    case eastWestNoResize = 50
    case northSouthNoResize = 51
    case northEastSouthWestNoResize = 52
    case northWestSouthEastNoResize = 53

    public var wireName: String {
        switch self {
        case .null, .pointer:
            return "pointer"
        case .cross:
            return "cross"
        case .hand:
            return "hand"
        case .iBeam:
            return "iBeam"
        case .wait:
            return "wait"
        case .help:
            return "help"
        case .eastResize, .westResize, .eastWestResize, .columnResize, .eastWestNoResize:
            return "eastWestResize"
        case .northResize, .southResize, .northSouthResize, .rowResize, .northSouthNoResize:
            return "northSouthResize"
        case .northEastResize, .southWestResize, .northEastSouthWestResize, .northEastSouthWestNoResize:
            return "northEastSouthWestResize"
        case .northWestResize, .southEastResize, .northWestSouthEastResize, .northWestSouthEastNoResize:
            return "northWestSouthEastResize"
        case .middlePanning, .middlePanningVertical, .middlePanningHorizontal,
                .eastPanning, .northPanning, .northEastPanning, .northWestPanning,
                .southPanning, .southEastPanning, .southWestPanning, .westPanning:
            return "panning"
        case .move:
            return "move"
        case .verticalText:
            return "verticalText"
        case .cell:
            return "cell"
        case .contextMenu:
            return "contextMenu"
        case .alias:
            return "alias"
        case .progress:
            return "progress"
        case .noDrop, .none, .notAllowed, .dndNone:
            return "notAllowed"
        case .copy, .dndCopy:
            return "copy"
        case .zoomIn:
            return "zoomIn"
        case .zoomOut:
            return "zoomOut"
        case .grab:
            return "grab"
        case .grabbing:
            return "grabbing"
        case .custom:
            return "custom"
        case .dndMove:
            return "dndMove"
        case .dndLink:
            return "dndLink"
        }
    }
}

public struct OwlFreshCursorInfo: Equatable, Codable, Sendable {
    public let type: Int32

    public init(type: Int32) {
        self.type = type
    }

    public var cursorType: OwlFreshCursorType {
        OwlFreshCursorType(rawValue: type) ?? .pointer
    }
}

public enum OwlFreshClientMojoInterfaceMarker {}
public typealias OwlFreshClientRemote = MojoPendingRemote<OwlFreshClientMojoInterfaceMarker>
public typealias OwlFreshClientReceiver = MojoPendingReceiver<OwlFreshClientMojoInterfaceMarker>

public protocol OwlFreshClientMojoInterface {
    func onReady(_ request: OwlFreshClientOnReadyRequest)
    func onCompositorChanged(_ compositor: OwlFreshCompositorInfo)
    func onSurfaceTreeChanged(_ surfaceTree: OwlFreshSurfaceTree)
    func onNavigationChanged(_ request: OwlFreshClientOnNavigationChangedRequest)
    func onHostLog(_ message: String)
    func onCursorChanged(_ cursor: OwlFreshCursorInfo)
}

public struct OwlFreshClientOnReadyRequest: Equatable, Codable {
    public let hostPid: Int32
    public let compositor: OwlFreshCompositorInfo

    public init(hostPid: Int32, compositor: OwlFreshCompositorInfo) {
        self.hostPid = hostPid
        self.compositor = compositor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostPid = try container.decode(Int32.self, forKey: .hostPid)
        self.compositor = try container.decode(OwlFreshCompositorInfo.self, forKey: .compositor)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostPid, forKey: .hostPid)
        try container.encode(compositor, forKey: .compositor)
    }

    private enum CodingKeys: String, CodingKey {
        case hostPid
        case compositor
    }
}

public struct OwlFreshClientOnNavigationChangedRequest: Equatable, Codable {
    public let url: String
    public let title: String
    public let loading: Bool
    public let canGoBack: Bool
    public let canGoForward: Bool

    public init(
        url: String,
        title: String,
        loading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        self.url = url
        self.title = title
        self.loading = loading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decode(String.self, forKey: .title)
        self.loading = try container.decode(Bool.self, forKey: .loading)
        self.canGoBack = try container.decode(Bool.self, forKey: .canGoBack)
        self.canGoForward = try container.decode(Bool.self, forKey: .canGoForward)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(loading, forKey: .loading)
        try container.encode(canGoBack, forKey: .canGoBack)
        try container.encode(canGoForward, forKey: .canGoForward)
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case title
        case loading
        case canGoBack
        case canGoForward
    }
}

public protocol OwlFreshClientMojoSink: AnyObject {
    func onReady(_ request: OwlFreshClientOnReadyRequest)
    func onCompositorChanged(_ compositor: OwlFreshCompositorInfo)
    func onSurfaceTreeChanged(_ surfaceTree: OwlFreshSurfaceTree)
    func onNavigationChanged(_ request: OwlFreshClientOnNavigationChangedRequest)
    func onHostLog(_ message: String)
    func onCursorChanged(_ cursor: OwlFreshCursorInfo)
}

public final class GeneratedOwlFreshClientMojoTransport: OwlFreshClientMojoInterface {
    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }
    private let sink: OwlFreshClientMojoSink
    private let recorder: OwlFreshMojoTransportRecorder

    public init(sink: OwlFreshClientMojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {
        self.sink = sink
        self.recorder = recorder
    }

    public func resetRecordedCalls() {
        recorder.reset()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recorder.record(
            interface: "OwlFreshClient",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        )
    }

    public func onReady(_ request: OwlFreshClientOnReadyRequest) {
        record(method: "onReady", payloadType: "OwlFreshClientOnReadyRequest", payloadSummary: String(describing: request))
        sink.onReady(request)
    }

    public func onCompositorChanged(_ compositor: OwlFreshCompositorInfo) {
        record(method: "onCompositorChanged", payloadType: "OwlFreshCompositorInfo", payloadSummary: String(describing: compositor))
        sink.onCompositorChanged(compositor)
    }

    public func onSurfaceTreeChanged(_ surfaceTree: OwlFreshSurfaceTree) {
        record(method: "onSurfaceTreeChanged", payloadType: "OwlFreshSurfaceTree", payloadSummary: String(describing: surfaceTree))
        sink.onSurfaceTreeChanged(surfaceTree)
    }

    public func onNavigationChanged(_ request: OwlFreshClientOnNavigationChangedRequest) {
        record(method: "onNavigationChanged", payloadType: "OwlFreshClientOnNavigationChangedRequest", payloadSummary: String(describing: request))
        sink.onNavigationChanged(request)
    }

    public func onHostLog(_ message: String) {
        record(method: "onHostLog", payloadType: "String", payloadSummary: String(describing: message))
        sink.onHostLog(message)
    }

    public func onCursorChanged(_ cursor: OwlFreshCursorInfo) {
        record(method: "onCursorChanged", payloadType: "OwlFreshCursorInfo", payloadSummary: String(describing: cursor))
        sink.onCursorChanged(cursor)
    }
}

public enum OwlFreshSessionMojoInterfaceMarker {}
public typealias OwlFreshSessionRemote = MojoPendingRemote<OwlFreshSessionMojoInterfaceMarker>
public typealias OwlFreshSessionReceiver = MojoPendingReceiver<OwlFreshSessionMojoInterfaceMarker>

public protocol OwlFreshSessionMojoInterface {
    func setClient(_ client: OwlFreshClientRemote)
    func bindProfile(_ profile: OwlFreshProfileReceiver)
    func bindWebView(_ webView: OwlFreshWebViewReceiver)
    func bindInput(_ input: OwlFreshInputReceiver)
    func bindSurfaceTree(_ surfaceTree: OwlFreshSurfaceTreeHostReceiver)
    func bindNativeSurfaceHost(_ nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver)
    func bindDevToolsHost(_ devtoolsHost: OwlFreshDevToolsHostReceiver)
    func flush() async throws -> Bool
}

public protocol OwlFreshSessionMojoSink: AnyObject {
    func setClient(_ client: OwlFreshClientRemote)
    func bindProfile(_ profile: OwlFreshProfileReceiver)
    func bindWebView(_ webView: OwlFreshWebViewReceiver)
    func bindInput(_ input: OwlFreshInputReceiver)
    func bindSurfaceTree(_ surfaceTree: OwlFreshSurfaceTreeHostReceiver)
    func bindNativeSurfaceHost(_ nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver)
    func bindDevToolsHost(_ devtoolsHost: OwlFreshDevToolsHostReceiver)
    func flush() async throws -> Bool
}

public final class GeneratedOwlFreshSessionMojoTransport: OwlFreshSessionMojoInterface {
    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }
    private let sink: OwlFreshSessionMojoSink
    private let recorder: OwlFreshMojoTransportRecorder

    public init(sink: OwlFreshSessionMojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {
        self.sink = sink
        self.recorder = recorder
    }

    public func resetRecordedCalls() {
        recorder.reset()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recorder.record(
            interface: "OwlFreshSession",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        )
    }

    public func setClient(_ client: OwlFreshClientRemote) {
        record(method: "setClient", payloadType: "OwlFreshClientRemote", payloadSummary: String(describing: client))
        sink.setClient(client)
    }

    public func bindProfile(_ profile: OwlFreshProfileReceiver) {
        record(method: "bindProfile", payloadType: "OwlFreshProfileReceiver", payloadSummary: String(describing: profile))
        sink.bindProfile(profile)
    }

    public func bindWebView(_ webView: OwlFreshWebViewReceiver) {
        record(method: "bindWebView", payloadType: "OwlFreshWebViewReceiver", payloadSummary: String(describing: webView))
        sink.bindWebView(webView)
    }

    public func bindInput(_ input: OwlFreshInputReceiver) {
        record(method: "bindInput", payloadType: "OwlFreshInputReceiver", payloadSummary: String(describing: input))
        sink.bindInput(input)
    }

    public func bindSurfaceTree(_ surfaceTree: OwlFreshSurfaceTreeHostReceiver) {
        record(method: "bindSurfaceTree", payloadType: "OwlFreshSurfaceTreeHostReceiver", payloadSummary: String(describing: surfaceTree))
        sink.bindSurfaceTree(surfaceTree)
    }

    public func bindNativeSurfaceHost(_ nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver) {
        record(method: "bindNativeSurfaceHost", payloadType: "OwlFreshNativeSurfaceHostReceiver", payloadSummary: String(describing: nativeSurfaceHost))
        sink.bindNativeSurfaceHost(nativeSurfaceHost)
    }

    public func bindDevToolsHost(_ devtoolsHost: OwlFreshDevToolsHostReceiver) {
        record(method: "bindDevToolsHost", payloadType: "OwlFreshDevToolsHostReceiver", payloadSummary: String(describing: devtoolsHost))
        sink.bindDevToolsHost(devtoolsHost)
    }

    public func flush() async throws -> Bool {
        record(method: "flush", payloadType: "Void", payloadSummary: "")
        return try await sink.flush()
    }
}

public enum OwlFreshProfileMojoInterfaceMarker {}
public typealias OwlFreshProfileRemote = MojoPendingRemote<OwlFreshProfileMojoInterfaceMarker>
public typealias OwlFreshProfileReceiver = MojoPendingReceiver<OwlFreshProfileMojoInterfaceMarker>

public protocol OwlFreshProfileMojoInterface {
    func getPath() async throws -> String
}

public protocol OwlFreshProfileMojoSink: AnyObject {
    func getPath() async throws -> String
}

public final class GeneratedOwlFreshProfileMojoTransport: OwlFreshProfileMojoInterface {
    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }
    private let sink: OwlFreshProfileMojoSink
    private let recorder: OwlFreshMojoTransportRecorder

    public init(sink: OwlFreshProfileMojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {
        self.sink = sink
        self.recorder = recorder
    }

    public func resetRecordedCalls() {
        recorder.reset()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recorder.record(
            interface: "OwlFreshProfile",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        )
    }

    public func getPath() async throws -> String {
        record(method: "getPath", payloadType: "Void", payloadSummary: "")
        return try await sink.getPath()
    }
}

public enum OwlFreshWebViewMojoInterfaceMarker {}
public typealias OwlFreshWebViewRemote = MojoPendingRemote<OwlFreshWebViewMojoInterfaceMarker>
public typealias OwlFreshWebViewReceiver = MojoPendingReceiver<OwlFreshWebViewMojoInterfaceMarker>

public protocol OwlFreshWebViewMojoInterface {
    func navigate(_ url: String)
    func resize(_ request: OwlFreshWebViewResizeRequest)
    func setFocus(_ focused: Bool)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
}

public struct OwlFreshWebViewResizeRequest: Equatable, Codable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let scale: Float

    public init(width: UInt32, height: UInt32, scale: Float) {
        self.width = width
        self.height = height
        self.scale = scale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try MojoJSONCoding.decodeUInt32(from: container, forKey: .width)
        self.height = try MojoJSONCoding.decodeUInt32(from: container, forKey: .height)
        self.scale = try container.decode(Float.self, forKey: .scale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(scale, forKey: .scale)
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case scale
    }
}

public protocol OwlFreshWebViewMojoSink: AnyObject {
    func navigate(_ url: String)
    func resize(_ request: OwlFreshWebViewResizeRequest)
    func setFocus(_ focused: Bool)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
}

public final class GeneratedOwlFreshWebViewMojoTransport: OwlFreshWebViewMojoInterface {
    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }
    private let sink: OwlFreshWebViewMojoSink
    private let recorder: OwlFreshMojoTransportRecorder

    public init(sink: OwlFreshWebViewMojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {
        self.sink = sink
        self.recorder = recorder
    }

    public func resetRecordedCalls() {
        recorder.reset()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recorder.record(
            interface: "OwlFreshWebView",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        )
    }

    public func navigate(_ url: String) {
        record(method: "navigate", payloadType: "String", payloadSummary: String(describing: url))
        sink.navigate(url)
    }

    public func resize(_ request: OwlFreshWebViewResizeRequest) {
        record(method: "resize", payloadType: "OwlFreshWebViewResizeRequest", payloadSummary: String(describing: request))
        sink.resize(request)
    }

    public func setFocus(_ focused: Bool) {
        record(method: "setFocus", payloadType: "Bool", payloadSummary: String(describing: focused))
        sink.setFocus(focused)
    }

    public func goBack() {
        record(method: "goBack", payloadType: "Void", payloadSummary: "")
        sink.goBack()
    }

    public func goForward() {
        record(method: "goForward", payloadType: "Void", payloadSummary: "")
        sink.goForward()
    }

    public func reload() {
        record(method: "reload", payloadType: "Void", payloadSummary: "")
        sink.reload()
    }

    public func stopLoading() {
        record(method: "stopLoading", payloadType: "Void", payloadSummary: "")
        sink.stopLoading()
    }
}

public enum OwlFreshInputMojoInterfaceMarker {}
public typealias OwlFreshInputRemote = MojoPendingRemote<OwlFreshInputMojoInterfaceMarker>
public typealias OwlFreshInputReceiver = MojoPendingReceiver<OwlFreshInputMojoInterfaceMarker>

public protocol OwlFreshInputMojoInterface {
    func sendMouse(_ event: OwlFreshMouseEvent)
    func sendWheel(_ event: OwlFreshWheelEvent)
    func sendKey(_ event: OwlFreshKeyEvent)
    func sendComposition(_ event: OwlFreshCompositionEvent)
    func executeEditCommand(_ command: String)
}

public protocol OwlFreshInputMojoSink: AnyObject {
    func sendMouse(_ event: OwlFreshMouseEvent)
    func sendWheel(_ event: OwlFreshWheelEvent)
    func sendKey(_ event: OwlFreshKeyEvent)
    func sendComposition(_ event: OwlFreshCompositionEvent)
    func executeEditCommand(_ command: String)
}

public final class GeneratedOwlFreshInputMojoTransport: OwlFreshInputMojoInterface {
    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }
    private let sink: OwlFreshInputMojoSink
    private let recorder: OwlFreshMojoTransportRecorder

    public init(sink: OwlFreshInputMojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {
        self.sink = sink
        self.recorder = recorder
    }

    public func resetRecordedCalls() {
        recorder.reset()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recorder.record(
            interface: "OwlFreshInput",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        )
    }

    public func sendMouse(_ event: OwlFreshMouseEvent) {
        record(method: "sendMouse", payloadType: "OwlFreshMouseEvent", payloadSummary: String(describing: event))
        sink.sendMouse(event)
    }

    public func sendWheel(_ event: OwlFreshWheelEvent) {
        record(method: "sendWheel", payloadType: "OwlFreshWheelEvent", payloadSummary: String(describing: event))
        sink.sendWheel(event)
    }

    public func sendKey(_ event: OwlFreshKeyEvent) {
        record(method: "sendKey", payloadType: "OwlFreshKeyEvent", payloadSummary: String(describing: event))
        sink.sendKey(event)
    }

    public func sendComposition(_ event: OwlFreshCompositionEvent) {
        record(method: "sendComposition", payloadType: "OwlFreshCompositionEvent", payloadSummary: String(describing: event))
        sink.sendComposition(event)
    }

    public func executeEditCommand(_ command: String) {
        record(method: "executeEditCommand", payloadType: "String", payloadSummary: String(describing: command))
        sink.executeEditCommand(command)
    }
}

public enum OwlFreshSurfaceTreeHostMojoInterfaceMarker {}
public typealias OwlFreshSurfaceTreeHostRemote = MojoPendingRemote<OwlFreshSurfaceTreeHostMojoInterfaceMarker>
public typealias OwlFreshSurfaceTreeHostReceiver = MojoPendingReceiver<OwlFreshSurfaceTreeHostMojoInterfaceMarker>

public protocol OwlFreshSurfaceTreeHostMojoInterface {
    func captureSurface() async throws -> OwlFreshCaptureResult
    func captureSurface(label: String) async throws -> OwlFreshCaptureResult
    func getSurfaceTree() async throws -> OwlFreshSurfaceTree
}

public protocol OwlFreshSurfaceTreeHostMojoSink: AnyObject {
    func captureSurface() async throws -> OwlFreshCaptureResult
    func captureSurface(label: String) async throws -> OwlFreshCaptureResult
    func getSurfaceTree() async throws -> OwlFreshSurfaceTree
}

public final class GeneratedOwlFreshSurfaceTreeHostMojoTransport: OwlFreshSurfaceTreeHostMojoInterface {
    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }
    private let sink: OwlFreshSurfaceTreeHostMojoSink
    private let recorder: OwlFreshMojoTransportRecorder

    public init(sink: OwlFreshSurfaceTreeHostMojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {
        self.sink = sink
        self.recorder = recorder
    }

    public func resetRecordedCalls() {
        recorder.reset()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recorder.record(
            interface: "OwlFreshSurfaceTreeHost",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        )
    }

    public func captureSurface() async throws -> OwlFreshCaptureResult {
        record(method: "captureSurface", payloadType: "Void", payloadSummary: "")
        return try await sink.captureSurface()
    }

    public func captureSurface(label: String) async throws -> OwlFreshCaptureResult {
        record(method: "captureSurfaceByLabel", payloadType: "String", payloadSummary: label)
        return try await sink.captureSurface(label: label)
    }

    public func getSurfaceTree() async throws -> OwlFreshSurfaceTree {
        record(method: "getSurfaceTree", payloadType: "Void", payloadSummary: "")
        return try await sink.getSurfaceTree()
    }
}

public enum OwlFreshNativeSurfaceHostMojoInterfaceMarker {}
public typealias OwlFreshNativeSurfaceHostRemote = MojoPendingRemote<OwlFreshNativeSurfaceHostMojoInterfaceMarker>
public typealias OwlFreshNativeSurfaceHostReceiver = MojoPendingReceiver<OwlFreshNativeSurfaceHostMojoInterfaceMarker>

public protocol OwlFreshNativeSurfaceHostMojoInterface {
    func acceptActivePopupMenuItem(_ index: UInt32) async throws -> Bool
    func cancelActivePopup() async throws -> Bool
    func selectActiveFilePickerFiles(_ paths: [String]) async throws -> Bool
    func cancelActiveFilePicker() async throws -> Bool
    func acceptActivePermissionPrompt() async throws -> Bool
    func cancelActivePermissionPrompt() async throws -> Bool
    func submitActiveAuthPrompt(username: String, password: String) async throws -> Bool
    func cancelActiveAuthPrompt() async throws -> Bool
}

public protocol OwlFreshNativeSurfaceHostMojoSink: AnyObject {
    func acceptActivePopupMenuItem(_ index: UInt32) async throws -> Bool
    func cancelActivePopup() async throws -> Bool
    func selectActiveFilePickerFiles(_ paths: [String]) async throws -> Bool
    func cancelActiveFilePicker() async throws -> Bool
    func acceptActivePermissionPrompt() async throws -> Bool
    func cancelActivePermissionPrompt() async throws -> Bool
    func submitActiveAuthPrompt(username: String, password: String) async throws -> Bool
    func cancelActiveAuthPrompt() async throws -> Bool
}

public final class GeneratedOwlFreshNativeSurfaceHostMojoTransport: OwlFreshNativeSurfaceHostMojoInterface {
    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }
    private let sink: OwlFreshNativeSurfaceHostMojoSink
    private let recorder: OwlFreshMojoTransportRecorder

    public init(sink: OwlFreshNativeSurfaceHostMojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {
        self.sink = sink
        self.recorder = recorder
    }

    public func resetRecordedCalls() {
        recorder.reset()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recorder.record(
            interface: "OwlFreshNativeSurfaceHost",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        )
    }

    public func acceptActivePopupMenuItem(_ index: UInt32) async throws -> Bool {
        record(method: "acceptActivePopupMenuItem", payloadType: "UInt32", payloadSummary: String(describing: index))
        return try await sink.acceptActivePopupMenuItem(index)
    }

    public func cancelActivePopup() async throws -> Bool {
        record(method: "cancelActivePopup", payloadType: "Void", payloadSummary: "")
        return try await sink.cancelActivePopup()
    }

    public func selectActiveFilePickerFiles(_ paths: [String]) async throws -> Bool {
        record(method: "selectActiveFilePickerFiles", payloadType: "[String]", payloadSummary: String(describing: paths))
        return try await sink.selectActiveFilePickerFiles(paths)
    }

    public func cancelActiveFilePicker() async throws -> Bool {
        record(method: "cancelActiveFilePicker", payloadType: "Void", payloadSummary: "")
        return try await sink.cancelActiveFilePicker()
    }

    public func acceptActivePermissionPrompt() async throws -> Bool {
        record(method: "acceptActivePermissionPrompt", payloadType: "Void", payloadSummary: "")
        return try await sink.acceptActivePermissionPrompt()
    }

    public func cancelActivePermissionPrompt() async throws -> Bool {
        record(method: "cancelActivePermissionPrompt", payloadType: "Void", payloadSummary: "")
        return try await sink.cancelActivePermissionPrompt()
    }

    public func submitActiveAuthPrompt(username: String, password: String) async throws -> Bool {
        record(method: "submitActiveAuthPrompt", payloadType: "(String, String)", payloadSummary: username)
        return try await sink.submitActiveAuthPrompt(username: username, password: password)
    }

    public func cancelActiveAuthPrompt() async throws -> Bool {
        record(method: "cancelActiveAuthPrompt", payloadType: "Void", payloadSummary: "")
        return try await sink.cancelActiveAuthPrompt()
    }
}

public enum OwlFreshDevToolsHostMojoInterfaceMarker {}
public typealias OwlFreshDevToolsHostRemote = MojoPendingRemote<OwlFreshDevToolsHostMojoInterfaceMarker>
public typealias OwlFreshDevToolsHostReceiver = MojoPendingReceiver<OwlFreshDevToolsHostMojoInterfaceMarker>

public protocol OwlFreshDevToolsHostMojoInterface {
    func openDevTools(_ mode: OwlFreshDevToolsMode) async throws -> Bool
    func closeDevTools() async throws -> Bool
    func evaluateDevToolsJavaScript(_ script: String) async throws -> String
}

public protocol OwlFreshDevToolsHostMojoSink: AnyObject {
    func openDevTools(_ mode: OwlFreshDevToolsMode) async throws -> Bool
    func closeDevTools() async throws -> Bool
    func evaluateDevToolsJavaScript(_ script: String) async throws -> String
}

public final class GeneratedOwlFreshDevToolsHostMojoTransport: OwlFreshDevToolsHostMojoInterface {
    public var recordedCalls: [OwlFreshMojoTransportCall] { recorder.recordedCalls }
    private let sink: OwlFreshDevToolsHostMojoSink
    private let recorder: OwlFreshMojoTransportRecorder

    public init(sink: OwlFreshDevToolsHostMojoSink, recorder: OwlFreshMojoTransportRecorder = OwlFreshMojoTransportRecorder()) {
        self.sink = sink
        self.recorder = recorder
    }

    public func resetRecordedCalls() {
        recorder.reset()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recorder.record(
            interface: "OwlFreshDevToolsHost",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        )
    }

    public func openDevTools(_ mode: OwlFreshDevToolsMode) async throws -> Bool {
        record(method: "openDevTools", payloadType: "OwlFreshDevToolsMode", payloadSummary: String(describing: mode))
        return try await sink.openDevTools(mode)
    }

    public func closeDevTools() async throws -> Bool {
        record(method: "closeDevTools", payloadType: "Void", payloadSummary: "")
        return try await sink.closeDevTools()
    }

    public func evaluateDevToolsJavaScript(_ script: String) async throws -> String {
        record(method: "evaluateDevToolsJavaScript", payloadType: "String", payloadSummary: String(describing: script))
        return try await sink.evaluateDevToolsJavaScript(script)
    }
}

public struct OwlFreshMojoSessionHandle: Equatable, @unchecked Sendable {
    public static let null = OwlFreshMojoSessionHandle(rawValue: nil)

    public let rawValue: OpaquePointer?

    public init(rawValue: OpaquePointer?) {
        self.rawValue = rawValue
    }
}

public protocol OwlFreshMojoPipeBindings: AnyObject {
    func sessionSetClient(_ session: OwlFreshMojoSessionHandle, client: OwlFreshClientRemote) throws
    func sessionBindProfile(_ session: OwlFreshMojoSessionHandle, profile: OwlFreshProfileReceiver) throws
    func sessionBindWebView(_ session: OwlFreshMojoSessionHandle, webView: OwlFreshWebViewReceiver) throws
    func sessionBindInput(_ session: OwlFreshMojoSessionHandle, input: OwlFreshInputReceiver) throws
    func sessionBindSurfaceTree(_ session: OwlFreshMojoSessionHandle, surfaceTree: OwlFreshSurfaceTreeHostReceiver) throws
    func sessionBindNativeSurfaceHost(_ session: OwlFreshMojoSessionHandle, nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver) throws
    func sessionBindDevToolsHost(_ session: OwlFreshMojoSessionHandle, devtoolsHost: OwlFreshDevToolsHostReceiver) throws
    func sessionFlush(_ session: OwlFreshMojoSessionHandle) throws -> Bool
    func profileGetPath(_ session: OwlFreshMojoSessionHandle) throws -> String
    func webViewNavigate(_ session: OwlFreshMojoSessionHandle, url: String) throws
    func webViewResize(_ session: OwlFreshMojoSessionHandle, request: OwlFreshWebViewResizeRequest) throws
    func webViewSetFocus(_ session: OwlFreshMojoSessionHandle, focused: Bool) throws
    func webViewGoBack(_ session: OwlFreshMojoSessionHandle) throws
    func webViewGoForward(_ session: OwlFreshMojoSessionHandle) throws
    func webViewReload(_ session: OwlFreshMojoSessionHandle) throws
    func webViewStopLoading(_ session: OwlFreshMojoSessionHandle) throws
    func inputSendMouse(_ session: OwlFreshMojoSessionHandle, event: OwlFreshMouseEvent) throws
    func inputSendWheel(_ session: OwlFreshMojoSessionHandle, event: OwlFreshWheelEvent) throws
    func inputSendKey(_ session: OwlFreshMojoSessionHandle, event: OwlFreshKeyEvent) throws
    func inputSendComposition(_ session: OwlFreshMojoSessionHandle, event: OwlFreshCompositionEvent) throws
    func inputExecuteEditCommand(_ session: OwlFreshMojoSessionHandle, command: String) throws
    func surfaceTreeHostCaptureSurface(_ session: OwlFreshMojoSessionHandle) throws -> OwlFreshCaptureResult
    func surfaceTreeHostCaptureSurface(_ session: OwlFreshMojoSessionHandle, label: String) throws -> OwlFreshCaptureResult
    func surfaceTreeHostGetSurfaceTree(_ session: OwlFreshMojoSessionHandle) throws -> OwlFreshSurfaceTree
    func nativeSurfaceHostAcceptActivePopupMenuItem(_ session: OwlFreshMojoSessionHandle, index: UInt32) throws -> Bool
    func nativeSurfaceHostCancelActivePopup(_ session: OwlFreshMojoSessionHandle) throws -> Bool
    func nativeSurfaceHostSelectActiveFilePickerFiles(_ session: OwlFreshMojoSessionHandle, paths: [String]) throws -> Bool
    func nativeSurfaceHostCancelActiveFilePicker(_ session: OwlFreshMojoSessionHandle) throws -> Bool
    func nativeSurfaceHostAcceptActivePermissionPrompt(_ session: OwlFreshMojoSessionHandle) throws -> Bool
    func nativeSurfaceHostCancelActivePermissionPrompt(_ session: OwlFreshMojoSessionHandle) throws -> Bool
    func nativeSurfaceHostSubmitActiveAuthPrompt(_ session: OwlFreshMojoSessionHandle, username: String, password: String) throws -> Bool
    func nativeSurfaceHostCancelActiveAuthPrompt(_ session: OwlFreshMojoSessionHandle) throws -> Bool
    func devToolsHostOpenDevTools(_ session: OwlFreshMojoSessionHandle, mode: OwlFreshDevToolsMode) throws -> Bool
    func devToolsHostCloseDevTools(_ session: OwlFreshMojoSessionHandle) throws -> Bool
    func devToolsHostEvaluateDevToolsJavaScript(_ session: OwlFreshMojoSessionHandle, script: String) throws -> String
}

public final class GeneratedOwlFreshMojoPipeBoundSinks:
    OwlFreshSessionMojoSink,
    OwlFreshProfileMojoSink,
    OwlFreshWebViewMojoSink,
    OwlFreshInputMojoSink,
    OwlFreshSurfaceTreeHostMojoSink,
    OwlFreshNativeSurfaceHostMojoSink,
    OwlFreshDevToolsHostMojoSink
{
    private let session: OwlFreshMojoSessionHandle
    private let pipe: OwlFreshMojoPipeBindings
    private var lastError: Error?

    public init(session: OwlFreshMojoSessionHandle, pipe: OwlFreshMojoPipeBindings) {
        self.session = session
        self.pipe = pipe
    }

    public func throwIfFailed() throws {
        if let error = lastError {
            lastError = nil
            throw error
        }
    }

    private func forward(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            lastError = error
        }
    }

    public func setClient(_ client: OwlFreshClientRemote) {
        forward {
            try pipe.sessionSetClient(session, client: client)
        }
    }

    public func bindProfile(_ profile: OwlFreshProfileReceiver) {
        forward {
            try pipe.sessionBindProfile(session, profile: profile)
        }
    }

    public func bindWebView(_ webView: OwlFreshWebViewReceiver) {
        forward {
            try pipe.sessionBindWebView(session, webView: webView)
        }
    }

    public func bindInput(_ input: OwlFreshInputReceiver) {
        forward {
            try pipe.sessionBindInput(session, input: input)
        }
    }

    public func bindSurfaceTree(_ surfaceTree: OwlFreshSurfaceTreeHostReceiver) {
        forward {
            try pipe.sessionBindSurfaceTree(session, surfaceTree: surfaceTree)
        }
    }

    public func bindNativeSurfaceHost(_ nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver) {
        forward {
            try pipe.sessionBindNativeSurfaceHost(session, nativeSurfaceHost: nativeSurfaceHost)
        }
    }

    public func bindDevToolsHost(_ devtoolsHost: OwlFreshDevToolsHostReceiver) {
        forward {
            try pipe.sessionBindDevToolsHost(session, devtoolsHost: devtoolsHost)
        }
    }

    public func flush() async throws -> Bool {
        return try pipe.sessionFlush(session)
    }

    public func getPath() async throws -> String {
        return try pipe.profileGetPath(session)
    }

    public func navigate(_ url: String) {
        forward {
            try pipe.webViewNavigate(session, url: url)
        }
    }

    public func resize(_ request: OwlFreshWebViewResizeRequest) {
        forward {
            try pipe.webViewResize(session, request: request)
        }
    }

    public func setFocus(_ focused: Bool) {
        forward {
            try pipe.webViewSetFocus(session, focused: focused)
        }
    }

    public func goBack() {
        forward {
            try pipe.webViewGoBack(session)
        }
    }

    public func goForward() {
        forward {
            try pipe.webViewGoForward(session)
        }
    }

    public func reload() {
        forward {
            try pipe.webViewReload(session)
        }
    }

    public func stopLoading() {
        forward {
            try pipe.webViewStopLoading(session)
        }
    }

    public func sendMouse(_ event: OwlFreshMouseEvent) {
        forward {
            try pipe.inputSendMouse(session, event: event)
        }
    }

    public func sendWheel(_ event: OwlFreshWheelEvent) {
        forward {
            try pipe.inputSendWheel(session, event: event)
        }
    }

    public func sendKey(_ event: OwlFreshKeyEvent) {
        forward {
            try pipe.inputSendKey(session, event: event)
        }
    }

    public func sendComposition(_ event: OwlFreshCompositionEvent) {
        forward {
            try pipe.inputSendComposition(session, event: event)
        }
    }

    public func executeEditCommand(_ command: String) {
        forward {
            try pipe.inputExecuteEditCommand(session, command: command)
        }
    }

    public func captureSurface() async throws -> OwlFreshCaptureResult {
        return try pipe.surfaceTreeHostCaptureSurface(session)
    }

    public func captureSurface(label: String) async throws -> OwlFreshCaptureResult {
        return try pipe.surfaceTreeHostCaptureSurface(session, label: label)
    }

    public func getSurfaceTree() async throws -> OwlFreshSurfaceTree {
        return try pipe.surfaceTreeHostGetSurfaceTree(session)
    }

    public func acceptActivePopupMenuItem(_ index: UInt32) async throws -> Bool {
        return try pipe.nativeSurfaceHostAcceptActivePopupMenuItem(session, index: index)
    }

    public func cancelActivePopup() async throws -> Bool {
        return try pipe.nativeSurfaceHostCancelActivePopup(session)
    }

    public func selectActiveFilePickerFiles(_ paths: [String]) async throws -> Bool {
        return try pipe.nativeSurfaceHostSelectActiveFilePickerFiles(session, paths: paths)
    }

    public func cancelActiveFilePicker() async throws -> Bool {
        return try pipe.nativeSurfaceHostCancelActiveFilePicker(session)
    }

    public func acceptActivePermissionPrompt() async throws -> Bool {
        return try pipe.nativeSurfaceHostAcceptActivePermissionPrompt(session)
    }

    public func cancelActivePermissionPrompt() async throws -> Bool {
        return try pipe.nativeSurfaceHostCancelActivePermissionPrompt(session)
    }

    public func submitActiveAuthPrompt(username: String, password: String) async throws -> Bool {
        return try pipe.nativeSurfaceHostSubmitActiveAuthPrompt(session, username: username, password: password)
    }

    public func cancelActiveAuthPrompt() async throws -> Bool {
        return try pipe.nativeSurfaceHostCancelActiveAuthPrompt(session)
    }

    public func openDevTools(_ mode: OwlFreshDevToolsMode) async throws -> Bool {
        return try pipe.devToolsHostOpenDevTools(session, mode: mode)
    }

    public func closeDevTools() async throws -> Bool {
        return try pipe.devToolsHostCloseDevTools(session)
    }

    public func evaluateDevToolsJavaScript(_ script: String) async throws -> String {
        return try pipe.devToolsHostEvaluateDevToolsJavaScript(session, script: script)
    }
}

public struct MojoSchemaDeclaration: Equatable, Codable, Sendable {
    public let kind: String
    public let name: String
}

public enum OwlFreshMojoSchema {
    public static let module = "content.mojom"
    public static let sourceChecksum = "fnv1a64:f37680d951808e20"
    public static let declarations: [MojoSchemaDeclaration] = [
        MojoSchemaDeclaration(kind: "enum", name: "OwlFreshMouseKind"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshMouseEvent"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshWheelEvent"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshKeyEvent"),
        MojoSchemaDeclaration(kind: "enum", name: "OwlFreshCompositionKind"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshCompositionEvent"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshCompositorInfo"),
        MojoSchemaDeclaration(kind: "enum", name: "OwlFreshSurfaceKind"),
        MojoSchemaDeclaration(kind: "enum", name: "OwlFreshDevToolsMode"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshNativeMenuItem"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshSurfaceInfo"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshSurfaceTree"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshCaptureResult"),
        MojoSchemaDeclaration(kind: "enum", name: "OwlFreshCursorType"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshCursorInfo"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshClient"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshSession"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshProfile"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshWebView"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshInput"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshSurfaceTreeHost"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshNativeSurfaceHost"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshDevToolsHost")
    ]
}
