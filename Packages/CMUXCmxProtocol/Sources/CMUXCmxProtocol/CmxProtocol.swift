import Foundation

nonisolated public let cmxProtocolVersion: UInt32 = 3
private let cmxMaxMessagePackCollectionCount = 1_000_000

nonisolated public struct CmxWireViewport: Equatable, Sendable {
  public var cols: UInt16
  public var rows: UInt16

  public init(cols: UInt16, rows: UInt16) {
    self.cols = cols
    self.rows = rows
  }
}

nonisolated public struct CmxWireTerminalViewport: Equatable, Sendable {
  public var tabID: UInt64
  public var cols: UInt16
  public var rows: UInt16

  public init(tabID: UInt64, cols: UInt16, rows: UInt16) {
    self.tabID = tabID
    self.cols = cols
    self.rows = rows
  }
}

nonisolated public enum CmxAttachedClientKind: String, Equatable, Sendable {
  case tui
  case native
}

nonisolated public enum CmxNativeClientKind: String, Equatable, Sendable {
  case desktop
  case iOS = "ios"
}

nonisolated public enum CmxNativeClientCapability: String, Equatable, Sendable {
  case libghosttyPtyBytes = "libghostty_pty_bytes"
  case webviewWorker = "webview_worker"
  case socketCompatibilityBridge = "socket_compatibility_bridge"
  case pasteboard
  case notifications
  case filePicker = "file_picker"
}

nonisolated public struct CmxAttachedClientInfo: Equatable, Sendable {
  public var clientID: String
  public var kind: CmxAttachedClientKind
  public var visibleTerminalCount: Int
  public var updatedAtMilliseconds: UInt64
  public var terminals: [CmxWireTerminalViewport]
  public var latencyMilliseconds: UInt32?
}

nonisolated public struct CmxNativeWorkspaceInfo: Equatable, Sendable {
  public var id: UInt64
  public var externalID: UUID?
  public var title: String
  public var description: String?
  public var latestSubmittedMessage: String?
  public var spaceCount: Int
  public var tabCount: Int
  public var terminalCount: Int
  public var pinned: Bool
  public var hasActivity: Bool
  public var bellCount: UInt64
  public var color: String?
  public var statusEntries: [CmxNativeSidebarStatusEntry]
  public var metadataBlocks: [CmxNativeSidebarMetadataBlock]
  public var logEntries: [CmxNativeSidebarLogEntry]
  public var progress: CmxNativeSidebarProgressState?

  public init(
    id: UInt64,
    externalID: UUID? = nil,
    title: String,
    description: String? = nil,
    latestSubmittedMessage: String? = nil,
    spaceCount: Int,
    tabCount: Int,
    terminalCount: Int,
    pinned: Bool,
    hasActivity: Bool = false,
    bellCount: UInt64 = 0,
    color: String?,
    statusEntries: [CmxNativeSidebarStatusEntry] = [],
    metadataBlocks: [CmxNativeSidebarMetadataBlock] = [],
    logEntries: [CmxNativeSidebarLogEntry] = [],
    progress: CmxNativeSidebarProgressState? = nil
  ) {
    self.id = id
    self.externalID = externalID
    self.title = title
    self.description = description
    self.latestSubmittedMessage = latestSubmittedMessage
    self.spaceCount = spaceCount
    self.tabCount = tabCount
    self.terminalCount = terminalCount
    self.pinned = pinned
    self.hasActivity = hasActivity
    self.bellCount = bellCount
    self.color = color
    self.statusEntries = statusEntries
    self.metadataBlocks = metadataBlocks
    self.logEntries = logEntries
    self.progress = progress
  }
}

nonisolated public struct CmxNativeSidebarStatusEntry: Equatable, Sendable {
  public var key: String
  public var value: String
  public var icon: String?
  public var color: String?
  public var url: String?
  public var priority: Int
  public var format: String
  public var updatedAtMilliseconds: UInt64
}

nonisolated public struct CmxNativeSidebarMetadataBlock: Equatable, Sendable {
  public var key: String
  public var markdown: String
  public var priority: Int
  public var updatedAtMilliseconds: UInt64
}

nonisolated public struct CmxNativeSidebarLogEntry: Equatable, Sendable {
  public var message: String
  public var level: String
  public var source: String?
  public var updatedAtMilliseconds: UInt64
}

nonisolated public struct CmxNativeSidebarProgressState: Equatable, Sendable {
  public var value: Double
  public var label: String?
}

nonisolated public struct CmxNativeSpaceInfo: Equatable, Sendable {
  public var id: UInt64
  public var title: String
  public var paneCount: Int
  public var terminalCount: Int
}

nonisolated public struct CmxNativeTabInfo: Equatable, Sendable {
  public var id: UInt64
  public var externalID: UUID?
  public var kind: CmxNativeTabKind
  public var title: String
  public var explicitTitle: Bool
  public var pinned: Bool
  public var hasActivity: Bool
  public var bellCount: UInt64
  public var cwd: String?
  public var gitBranch: CmxNativeGitBranchInfo?
  public var pullRequest: CmxNativePullRequestInfo?
  public var ttyName: String?
  public var shellState: String?
  public var portsKickGeneration: UInt64
  public var listeningPorts: [Int]
  public var browser: CmxNativeBrowserInfo?

  public init(
    id: UInt64,
    externalID: UUID? = nil,
    kind: CmxNativeTabKind = .terminal,
    title: String,
    explicitTitle: Bool = false,
    pinned: Bool = false,
    hasActivity: Bool = false,
    bellCount: UInt64 = 0,
    cwd: String? = nil,
    gitBranch: CmxNativeGitBranchInfo? = nil,
    pullRequest: CmxNativePullRequestInfo? = nil,
    ttyName: String? = nil,
    shellState: String? = nil,
    portsKickGeneration: UInt64 = 0,
    listeningPorts: [Int] = [],
    browser: CmxNativeBrowserInfo? = nil
  ) {
    self.id = id
    self.externalID = externalID
    self.kind = kind
    self.title = title
    self.explicitTitle = explicitTitle
    self.pinned = pinned
    self.hasActivity = hasActivity
    self.bellCount = bellCount
    self.cwd = cwd
    self.gitBranch = gitBranch
    self.pullRequest = pullRequest
    self.ttyName = ttyName
    self.shellState = shellState
    self.portsKickGeneration = portsKickGeneration
    self.listeningPorts = listeningPorts
    self.browser = browser
  }
}

nonisolated public enum CmxNativeTabKind: String, Equatable, Sendable {
  case terminal
  case browser
}

nonisolated public struct CmxNativeGitBranchInfo: Equatable, Sendable {
  public var branch: String
  public var isDirty: Bool

  public init(branch: String, isDirty: Bool = false) {
    self.branch = branch
    self.isDirty = isDirty
  }
}

nonisolated public struct CmxNativePullRequestInfo: Equatable, Sendable {
  public var number: Int
  public var label: String
  public var urlString: String
  public var status: String
  public var branch: String?
  public var isStale: Bool

  public init(
    number: Int,
    label: String,
    urlString: String,
    status: String,
    branch: String? = nil,
    isStale: Bool = false
  ) {
    self.number = number
    self.label = label
    self.urlString = urlString
    self.status = status
    self.branch = branch
    self.isStale = isStale
  }
}

nonisolated public struct CmxNativeBrowserInfo: Equatable, Sendable {
  public var urlString: String?
  public var title: String?
  public var profileID: String?
  public var shouldRenderWebView: Bool
  public var pageZoom: Double?
  public var developerToolsVisible: Bool
  public var backHistoryURLStrings: [String]
  public var forwardHistoryURLStrings: [String]
  public var proxy: CmxNativeBrowserProxyContext?
  public var reloadGeneration: UInt64

  public init(
    urlString: String?,
    title: String?,
    profileID: String?,
    shouldRenderWebView: Bool,
    pageZoom: Double?,
    developerToolsVisible: Bool,
    backHistoryURLStrings: [String],
    forwardHistoryURLStrings: [String],
    proxy: CmxNativeBrowserProxyContext? = nil,
    reloadGeneration: UInt64 = 0
  ) {
    self.urlString = urlString
    self.title = title
    self.profileID = profileID
    self.shouldRenderWebView = shouldRenderWebView
    self.pageZoom = pageZoom
    self.developerToolsVisible = developerToolsVisible
    self.backHistoryURLStrings = backHistoryURLStrings
    self.forwardHistoryURLStrings = forwardHistoryURLStrings
    self.proxy = proxy
    self.reloadGeneration = reloadGeneration
  }
}

nonisolated public struct CmxNativeBrowserProxyContext: Equatable, Sendable {
  public var host: String
  public var port: UInt16
  public var target: String?

  public init(host: String, port: UInt16, target: String? = nil) {
    self.host = host
    self.port = port
    self.target = target
  }
}

nonisolated public struct CmxNativeTabSelection: Equatable, Sendable {
  public var panelID: UInt64
  public var index: Int
}

nonisolated public enum CmxNativeSplitDirection: String, Equatable, Sendable {
  case horizontal
  case vertical
}

nonisolated public enum CmxSplitDropEdge: String, Equatable, Sendable {
  case left
  case right
  case top
  case bottom
}

nonisolated public indirect enum CmxNativePanelNode: Equatable, Sendable {
  case leaf(panelID: UInt64, tabs: [CmxNativeTabInfo], active: Int, activeTabID: UInt64)
  case split(
    direction: CmxNativeSplitDirection,
    ratioPermille: UInt16,
    first: CmxNativePanelNode,
    second: CmxNativePanelNode
  )

  public var flattenedTabs: [CmxNativeTabInfo] {
    switch self {
    case .leaf(_, let tabs, _, _):
      tabs
    case .split(_, _, let first, let second):
      first.flattenedTabs + second.flattenedTabs
    }
  }

  public func selection(for tabID: UInt64) -> CmxNativeTabSelection? {
    switch self {
    case .leaf(let panelID, let tabs, _, _):
      guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
      return CmxNativeTabSelection(panelID: panelID, index: index)
    case .split(_, _, let first, let second):
      return first.selection(for: tabID) ?? second.selection(for: tabID)
    }
  }
}

nonisolated public struct CmxNativeSnapshot: Equatable, Sendable {
  public var revision: UInt64
  public var windowID: String?
  public var nativeWindowIDs: [String]
  public var workspaces: [CmxNativeWorkspaceInfo]
  public var activeWorkspace: Int
  public var activeWorkspaceID: UInt64
  public var spaces: [CmxNativeSpaceInfo]
  public var activeSpace: Int
  public var activeSpaceID: UInt64
  public var panels: CmxNativePanelNode
  public var focusedPanelID: UInt64
  public var focusedTabID: UInt64
  public var attachedClients: [CmxAttachedClientInfo] = []
  public var terminalTheme: CmxNativeTerminalThemeSet? = nil
  public var terminalFont: CmxNativeTerminalFont? = nil
  public var terminalCursor: CmxNativeTerminalCursor? = nil
  public var browserFocusRequest: CmxNativeBrowserFocusRequest? = nil

  public init(
    revision: UInt64 = 0,
    windowID: String? = nil,
    nativeWindowIDs: [String] = [],
    workspaces: [CmxNativeWorkspaceInfo],
    activeWorkspace: Int,
    activeWorkspaceID: UInt64,
    spaces: [CmxNativeSpaceInfo],
    activeSpace: Int,
    activeSpaceID: UInt64,
    panels: CmxNativePanelNode,
    focusedPanelID: UInt64,
    focusedTabID: UInt64,
    attachedClients: [CmxAttachedClientInfo] = [],
    terminalTheme: CmxNativeTerminalThemeSet? = nil,
    terminalFont: CmxNativeTerminalFont? = nil,
    terminalCursor: CmxNativeTerminalCursor? = nil,
    browserFocusRequest: CmxNativeBrowserFocusRequest? = nil
  ) {
    self.revision = revision
    self.windowID = windowID
    self.nativeWindowIDs = nativeWindowIDs
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
    self.activeWorkspaceID = activeWorkspaceID
    self.spaces = spaces
    self.activeSpace = activeSpace
    self.activeSpaceID = activeSpaceID
    self.panels = panels
    self.focusedPanelID = focusedPanelID
    self.focusedTabID = focusedTabID
    self.attachedClients = attachedClients
    self.terminalTheme = terminalTheme
    self.terminalFont = terminalFont
    self.terminalCursor = terminalCursor
    self.browserFocusRequest = browserFocusRequest
  }
}

nonisolated public struct CmxNativeBrowserFocusRequest: Equatable, Sendable {
  public var tabID: UInt64
  public var generation: UInt64

  public init(tabID: UInt64, generation: UInt64) {
    self.tabID = tabID
    self.generation = generation
  }
}

nonisolated public struct CmxTerminalRGB: Equatable, Sendable {
  public var r: UInt8
  public var g: UInt8
  public var b: UInt8
}

nonisolated public enum CmxNativeTerminalCursorStyle: String, Equatable, Sendable {
  case block
  case hollowBlock = "hollow_block"
  case underline
  case bar
}

nonisolated public struct CmxNativeTerminalCursorPosition: Equatable, Sendable {
  public var col: UInt16
  public var row: UInt16
  public var visible: Bool
  public var style: CmxNativeTerminalCursorStyle
  public var blink: Bool
  public var color: CmxTerminalRGB?
}

nonisolated public struct CmxNativeTerminalGridCell: Equatable, Sendable {
  public var text: String
  public var width: UInt8
  public var fg: CmxTerminalRGB
  public var bg: CmxTerminalRGB
  public var bold: Bool
  public var italic: Bool
  public var underline: Bool
  public var faint: Bool
  public var blink: Bool
  public var strikethrough: Bool
}

nonisolated public struct CmxNativeTerminalGridSnapshot: Equatable, Sendable {
  public var tabID: UInt64
  public var cols: UInt16
  public var rows: UInt16
  public var cells: [CmxNativeTerminalGridCell]
  public var cursor: CmxNativeTerminalCursorPosition?
}

nonisolated public enum CmxTerminalColorPreference: Equatable, Sendable {
  case light
  case dark
}

nonisolated public struct CmxNativeTerminalThemeSet: Equatable, Sendable {
  public var defaultTheme: CmxNativeTerminalTheme?
  public var light: CmxNativeTerminalTheme?
  public var dark: CmxNativeTerminalTheme?

  public func effectiveTheme(colorPreference: CmxTerminalColorPreference) -> CmxNativeTerminalTheme?
  {
    switch colorPreference {
    case .light:
      light ?? defaultTheme ?? dark
    case .dark:
      dark ?? defaultTheme ?? light
    }
  }
}

nonisolated public struct CmxNativeTerminalTheme: Equatable, Sendable {
  public var palette: [UInt8: String]
  public var foreground: String?
  public var background: String?
  public var cursor: String?
  public var cursorAccent: String?
  public var selectionBackground: String?
  public var selectionForeground: String?
  public var black: String?
  public var red: String?
  public var green: String?
  public var yellow: String?
  public var blue: String?
  public var magenta: String?
  public var cyan: String?
  public var white: String?
  public var brightBlack: String?
  public var brightRed: String?
  public var brightGreen: String?
  public var brightYellow: String?
  public var brightBlue: String?
  public var brightMagenta: String?
  public var brightCyan: String?
  public var brightWhite: String?
}

nonisolated public struct CmxNativeTerminalFont: Equatable, Sendable {
  public var families: [String]
  public var size: Double?
}

nonisolated public struct CmxNativeTerminalCursor: Equatable, Sendable {
  public var style: String?
  public var blink: Bool?
}

nonisolated public enum CmxClientMessage: Equatable, Sendable {
  case hello(viewport: CmxWireViewport, token: String?)
  case helloNative(
    viewport: CmxWireViewport,
    token: String?,
    clientKind: CmxNativeClientKind = .desktop,
    clientID: String? = nil,
    windowID: String? = nil,
    capabilities: [CmxNativeClientCapability] = [.libghosttyPtyBytes]
  )
  case input(Data)
  case resize(CmxWireViewport)
  case nativeInput(tabID: UInt64, data: Data)
  case nativeLayout([CmxWireTerminalViewport])
  case requestPtyReplay(tabID: UInt64, fromSeq: UInt64? = nil)
  case nativeBrowserUpdate(tabID: UInt64, browser: CmxNativeBrowserInfo)
  case nativeBrowserFocusUpdate(tabID: UInt64, webViewFocused: Bool)
  case nativeCompatibilityReply(requestID: UInt64, responseJSON: String)
  case command(id: UInt32, CmxClientCommand)
  case detach
  case ping
  case clientLatency(milliseconds: UInt32)
}

nonisolated public enum CmxClientCommand: Equatable, Sendable {
  case newTab
  case newTabWithOptions(cwd: String? = nil, initialInput: String? = nil)
  case newBrowserTab(urlString: String? = nil)
  case newBrowserSplit(urlString: String? = nil, vertical: Bool = false)
  case browserNavigate(urlString: String)
  case browserBack
  case browserForward
  case browserReload
  case browserGetURL
  case newWorkspace(title: String? = nil, cwd: String? = nil)
  case closeWorkspaceByID(workspaceID: UInt64)
  case closeWindowByID(windowID: String)
  case renameWorkspaceByID(workspaceID: UInt64, title: String)
  case selectTab(index: Int)
  case nextTab
  case previousTab
  case closeTab
  case splitHorizontal
  case splitHorizontalWithOptions(cwd: String? = nil, initialInput: String? = nil)
  case splitVertical
  case splitVerticalWithOptions(cwd: String? = nil, initialInput: String? = nil)
  case selectWorkspace(index: Int)
  case moveWorkspaceToIndex(workspaceID: UInt64, index: Int)
  case setWorkspaceRemoteStatus(workspaceID: UInt64, statusJSON: String?)
  case selectSpace(index: Int)
  case selectTabInPanel(panelID: UInt64, index: Int)
  case moveTabToPanel(
    fromPanelID: UInt64, from: Int, toPanelID: UInt64, to: Int, focus: Bool = true)
  case moveTabToSplit(
    fromPanelID: UInt64, from: Int, targetPanelID: UInt64, edge: CmxSplitDropEdge,
    focus: Bool = true)
  case setTabTitleByID(tabID: UInt64, title: String?, explicit: Bool = true)
  case focusPanel(panelID: UInt64)
  case setWorkspacePinned(workspaceID: UInt64, pinned: Bool)
  case setWorkspaceUnread(workspaceID: UInt64, unread: Bool)
  case setWorkspaceDescriptionByID(workspaceID: UInt64, description: String?)
  case setWorkspaceColorByID(workspaceID: UInt64, color: String?)
}

nonisolated public enum CmxServerMessage: Equatable, Sendable {
  case welcome(serverVersion: String, sessionID: String)
  case ptyBytes(tabID: UInt64, data: Data, seq: UInt64? = nil)
  case hostControl(Data)
  case commandReply(id: UInt32)
  case activeTabChanged(index: Int, tabID: UInt64)
  case activeWorkspaceChanged(index: Int, workspaceID: UInt64, title: String)
  case activeSpaceChanged(index: Int, spaceID: UInt64, title: String)
  case nativeSnapshot(CmxNativeSnapshot)
  case terminalGridSnapshot(CmxNativeTerminalGridSnapshot)
  case nativeCompatibilityRequest(requestID: UInt64, requestJSON: String)
  case bye
  case pong
  case error(String)
  case unsupported(kind: String)
}

nonisolated public enum CmxWireError: Error, Equatable, LocalizedError {
  case invalidMessage(String)
  case unsupportedMessagePack(UInt8)
  case unexpectedEnd
  case invalidUTF8
  case expectedMap
  case expectedString
  case expectedData
  case expectedInteger

  public var errorDescription: String? {
    switch self {
    case .invalidMessage(let message):
      message
    case .unsupportedMessagePack(let byte):
      String(format: "Unsupported MessagePack byte 0x%02X.", byte)
    case .unexpectedEnd:
      "Unexpected end of cmx protocol frame."
    case .invalidUTF8:
      "Invalid UTF-8 in cmx protocol frame."
    case .expectedMap:
      "Expected MessagePack map."
    case .expectedString:
      "Expected MessagePack string."
    case .expectedData:
      "Expected MessagePack binary data."
    case .expectedInteger:
      "Expected MessagePack integer."
    }
  }
}

public enum CmxWireCodec {
  public static func encode(_ message: CmxClientMessage) throws -> Data {
    var writer = MessagePackWriter()
    switch message {
    case .hello(let viewport, let token):
      writer.writeMapHeader(4)
      writer.writeString("kind")
      writer.writeString("hello")
      writer.writeString("version")
      writer.writeUInt(UInt64(cmxProtocolVersion))
      writer.writeString("viewport")
      writeViewport(viewport, to: &writer)
      writer.writeString("token")
      if let token {
        writer.writeString(token)
      } else {
        writer.writeNil()
      }
    case .helloNative(
      let viewport, let token, let clientKind, let clientID, let windowID, let capabilities):
      writer.writeMapHeader(9)
      writer.writeString("kind")
      writer.writeString("hello_native")
      writer.writeString("version")
      writer.writeUInt(UInt64(cmxProtocolVersion))
      writer.writeString("viewport")
      writeViewport(viewport, to: &writer)
      writer.writeString("token")
      if let token {
        writer.writeString(token)
      } else {
        writer.writeNil()
      }
      writer.writeString("terminal_renderer")
      writer.writeString("libghostty")
      writer.writeString("client_kind")
      writer.writeString(clientKind.rawValue)
      writer.writeString("client_id")
      if let clientID {
        writer.writeString(clientID)
      } else {
        writer.writeNil()
      }
      writer.writeString("window_id")
      if let windowID {
        writer.writeString(windowID)
      } else {
        writer.writeNil()
      }
      writer.writeString("capabilities")
      writer.writeArrayHeader(capabilities.count)
      for capability in capabilities {
        writer.writeString(capability.rawValue)
      }
    case .input(let data):
      writer.writeMapHeader(2)
      writer.writeString("kind")
      writer.writeString("input")
      writer.writeString("data")
      writer.writeBinary(data)
    case .resize(let viewport):
      writer.writeMapHeader(2)
      writer.writeString("kind")
      writer.writeString("resize")
      writer.writeString("viewport")
      writeViewport(viewport, to: &writer)
    case .nativeInput(let tabID, let data):
      writer.writeMapHeader(3)
      writer.writeString("kind")
      writer.writeString("native_input")
      writer.writeString("tab_id")
      writer.writeUInt(tabID)
      writer.writeString("data")
      writer.writeBinary(data)
    case .nativeLayout(let terminals):
      writer.writeMapHeader(2)
      writer.writeString("kind")
      writer.writeString("native_layout")
      writer.writeString("terminals")
      writer.writeArrayHeader(terminals.count)
      for terminal in terminals {
        writer.writeMapHeader(3)
        writer.writeString("tab_id")
        writer.writeUInt(terminal.tabID)
        writer.writeString("cols")
        writer.writeUInt(UInt64(terminal.cols))
        writer.writeString("rows")
        writer.writeUInt(UInt64(terminal.rows))
      }
    case .requestPtyReplay(let tabID, let fromSeq):
      writer.writeMapHeader(3)
      writer.writeString("kind")
      writer.writeString("request_pty_replay")
      writer.writeString("tab_id")
      writer.writeUInt(tabID)
      writer.writeString("from_seq")
      if let fromSeq {
        writer.writeUInt(fromSeq)
      } else {
        writer.writeNil()
      }
    case .nativeBrowserUpdate(let tabID, let browser):
      writer.writeMapHeader(3)
      writer.writeString("kind")
      writer.writeString("native_browser_update")
      writer.writeString("tab_id")
      writer.writeUInt(tabID)
      writer.writeString("browser")
      writeBrowserInfo(browser, to: &writer)
    case .nativeBrowserFocusUpdate(let tabID, let webViewFocused):
      writer.writeMapHeader(3)
      writer.writeString("kind")
      writer.writeString("native_browser_focus_update")
      writer.writeString("tab_id")
      writer.writeUInt(tabID)
      writer.writeString("webview_focused")
      writer.writeBool(webViewFocused)
    case .nativeCompatibilityReply(let requestID, let responseJSON):
      writer.writeMapHeader(3)
      writer.writeString("kind")
      writer.writeString("native_compatibility_reply")
      writer.writeString("request_id")
      writer.writeUInt(requestID)
      writer.writeString("response_json")
      writer.writeString(responseJSON)
    case .command(let id, let command):
      writer.writeMapHeader(3)
      writer.writeString("kind")
      writer.writeString("command")
      writer.writeString("id")
      writer.writeUInt(UInt64(id))
      writer.writeString("command")
      writeCommand(command, to: &writer)
    case .detach:
      writer.writeMapHeader(1)
      writer.writeString("kind")
      writer.writeString("detach")
    case .ping:
      writer.writeMapHeader(1)
      writer.writeString("kind")
      writer.writeString("ping")
    case .clientLatency(let milliseconds):
      writer.writeMapHeader(2)
      writer.writeString("kind")
      writer.writeString("client_latency")
      writer.writeString("latency_ms")
      writer.writeUInt(UInt64(milliseconds))
    }
    return writer.data
  }

  public static func decodeServerMessage(_ data: Data) throws -> CmxServerMessage {
    var reader = MessagePackReader(data: data)
    let value = try reader.readValue()
    guard reader.isAtEnd else {
      throw CmxWireError.invalidMessage("Trailing bytes after cmx protocol frame.")
    }
    let map = try value.mapValue()
    guard let kind = try map["kind"]?.stringValue() else {
      throw CmxWireError.invalidMessage("Missing server message kind.")
    }
    switch kind {
    case "welcome":
      return .welcome(
        serverVersion: try requiredString(map, "server_version"),
        sessionID: try requiredString(map, "session_id")
      )
    case "pty_bytes":
      return .ptyBytes(
        tabID: try requiredUInt(map, "tab_id"),
        data: try requiredData(map, "data"),
        seq: try optionalUInt(map, "seq")
      )
    case "host_control":
      return .hostControl(try requiredData(map, "data"))
    case "command_reply":
      return .commandReply(id: UInt32(clamping: try requiredUInt(map, "id")))
    case "active_tab_changed":
      return .activeTabChanged(
        index: try requiredInt(map, "index"),
        tabID: try requiredUInt(map, "tab_id")
      )
    case "active_workspace_changed":
      return .activeWorkspaceChanged(
        index: try requiredInt(map, "index"),
        workspaceID: try requiredUInt(map, "workspace_id"),
        title: try requiredString(map, "title")
      )
    case "active_space_changed":
      return .activeSpaceChanged(
        index: try requiredInt(map, "index"),
        spaceID: try requiredUInt(map, "space_id"),
        title: try requiredString(map, "title")
      )
    case "native_snapshot":
      return .nativeSnapshot(try decodeNativeSnapshot(try requiredMap(map, "snapshot")))
    case "terminal_grid_snapshot":
      return .terminalGridSnapshot(try decodeTerminalGridSnapshot(try requiredMap(map, "snapshot")))
    case "native_compatibility_request":
      return .nativeCompatibilityRequest(
        requestID: try requiredUInt(map, "request_id"),
        requestJSON: try requiredString(map, "request_json")
      )
    case "bye":
      return .bye
    case "pong":
      return .pong
    case "error":
      return .error(try requiredString(map, "message"))
    default:
      return .unsupported(kind: kind)
    }
  }

  public static func frame(_ payload: Data) throws -> Data {
    guard payload.count <= Int(UInt32.max) else {
      throw CmxWireError.invalidMessage("cmx frame is too large.")
    }
    var framed = Data()
    let len = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: len) { framed.append(contentsOf: $0) }
    framed.append(payload)
    return framed
  }

  private static func writeViewport(_ viewport: CmxWireViewport, to writer: inout MessagePackWriter)
  {
    writer.writeMapHeader(2)
    writer.writeString("cols")
    writer.writeUInt(UInt64(viewport.cols))
    writer.writeString("rows")
    writer.writeUInt(UInt64(viewport.rows))
  }

  private static func writeBrowserInfo(
    _ browser: CmxNativeBrowserInfo, to writer: inout MessagePackWriter
  ) {
    writer.writeMapHeader(10)
    writer.writeString("url")
    writeOptionalString(browser.urlString, to: &writer)
    writer.writeString("title")
    writeOptionalString(browser.title, to: &writer)
    writer.writeString("profile_id")
    writeOptionalString(browser.profileID, to: &writer)
    writer.writeString("should_render_webview")
    writer.writeBool(browser.shouldRenderWebView)
    writer.writeString("page_zoom")
    if let pageZoom = browser.pageZoom {
      writer.writeFloat64(pageZoom)
    } else {
      writer.writeNil()
    }
    writer.writeString("developer_tools_visible")
    writer.writeBool(browser.developerToolsVisible)
    writer.writeString("back_history_url_strings")
    writeStringArray(browser.backHistoryURLStrings, to: &writer)
    writer.writeString("forward_history_url_strings")
    writeStringArray(browser.forwardHistoryURLStrings, to: &writer)
    writer.writeString("proxy")
    if let proxy = browser.proxy {
      writer.writeMapHeader(3)
      writer.writeString("host")
      writer.writeString(proxy.host)
      writer.writeString("port")
      writer.writeUInt(UInt64(proxy.port))
      writer.writeString("target")
      writeOptionalString(proxy.target, to: &writer)
    } else {
      writer.writeNil()
    }
    writer.writeString("reload_generation")
    writer.writeUInt(browser.reloadGeneration)
  }

  private static func writeOptionalString(_ value: String?, to writer: inout MessagePackWriter) {
    if let value {
      writer.writeString(value)
    } else {
      writer.writeNil()
    }
  }

  private static func writeStringArray(_ values: [String], to writer: inout MessagePackWriter) {
    writer.writeArrayHeader(values.count)
    for value in values {
      writer.writeString(value)
    }
  }

  private static func writeCommand(_ command: CmxClientCommand, to writer: inout MessagePackWriter)
  {
    switch command {
    case .newTab:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("new-tab")
    case .newTabWithOptions(let cwd, let initialInput):
      writeTerminalSeedCommand(
        name: "new-tab-with-options",
        cwd: cwd,
        initialInput: initialInput,
        to: &writer
      )
    case .newBrowserTab(let urlString):
      let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasURL = urlString?.isEmpty == false
      writer.writeMapHeader(1 + (hasURL ? 1 : 0))
      writer.writeString("name")
      writer.writeString("new-browser-tab")
      if hasURL, let urlString {
        writer.writeString("url")
        writer.writeString(urlString)
      }
    case .newBrowserSplit(let urlString, let vertical):
      let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasURL = urlString?.isEmpty == false
      writer.writeMapHeader(2 + (hasURL ? 1 : 0))
      writer.writeString("name")
      writer.writeString("new-browser-split")
      writer.writeString("vertical")
      writer.writeBool(vertical)
      if hasURL, let urlString {
        writer.writeString("url")
        writer.writeString(urlString)
      }
    case .browserNavigate(let urlString):
      writer.writeMapHeader(2)
      writer.writeString("name")
      writer.writeString("browser-navigate")
      writer.writeString("url")
      writer.writeString(urlString)
    case .browserBack:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("browser-back")
    case .browserForward:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("browser-forward")
    case .browserReload:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("browser-reload")
    case .browserGetURL:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("browser-get-url")
    case .newWorkspace(let title, let cwd):
      let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasTitle = title?.isEmpty == false
      let hasCwd = cwd?.isEmpty == false
      writer.writeMapHeader(1 + (hasTitle ? 1 : 0) + (hasCwd ? 1 : 0))
      writer.writeString("name")
      writer.writeString("new-workspace")
      if hasTitle, let title {
        writer.writeString("title")
        writer.writeString(title)
      }
      if hasCwd, let cwd {
        writer.writeString("cwd")
        writer.writeString(cwd)
      }
    case .closeWorkspaceByID(let workspaceID):
      writer.writeMapHeader(2)
      writer.writeString("name")
      writer.writeString("close-workspace-by-id")
      writer.writeString("workspace_id")
      writer.writeUInt(workspaceID)
    case .closeWindowByID(let windowID):
      writer.writeMapHeader(2)
      writer.writeString("name")
      writer.writeString("close-window-by-id")
      writer.writeString("window_id")
      writer.writeString(windowID)
    case .renameWorkspaceByID(let workspaceID, let title):
      writer.writeMapHeader(3)
      writer.writeString("name")
      writer.writeString("rename-workspace-by-id")
      writer.writeString("workspace_id")
      writer.writeUInt(workspaceID)
      writer.writeString("title")
      writer.writeString(title)
    case .selectTab(let index):
      writer.writeMapHeader(2)
      writer.writeString("name")
      writer.writeString("select-tab")
      writer.writeString("index")
      writer.writeUInt(UInt64(index))
    case .nextTab:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("next-tab")
    case .previousTab:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("prev-tab")
    case .closeTab:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("close-tab")
    case .splitHorizontal:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("split-horizontal")
    case .splitHorizontalWithOptions(let cwd, let initialInput):
      writeTerminalSeedCommand(
        name: "split-horizontal-with-options",
        cwd: cwd,
        initialInput: initialInput,
        to: &writer
      )
    case .splitVertical:
      writer.writeMapHeader(1)
      writer.writeString("name")
      writer.writeString("split-vertical")
    case .splitVerticalWithOptions(let cwd, let initialInput):
      writeTerminalSeedCommand(
        name: "split-vertical-with-options",
        cwd: cwd,
        initialInput: initialInput,
        to: &writer
      )
    case .selectWorkspace(let index):
      writer.writeMapHeader(2)
      writer.writeString("name")
      writer.writeString("select-workspace")
      writer.writeString("index")
      writer.writeUInt(UInt64(index))
    case .moveWorkspaceToIndex(let workspaceID, let index):
      writer.writeMapHeader(3)
      writer.writeString("name")
      writer.writeString("move-workspace-to-index")
      writer.writeString("workspace_id")
      writer.writeUInt(workspaceID)
      writer.writeString("index")
      writer.writeUInt(UInt64(max(0, index)))
    case .setWorkspaceRemoteStatus(let workspaceID, let statusJSON):
      writer.writeMapHeader(3)
      writer.writeString("name")
      writer.writeString("set-workspace-remote-status")
      writer.writeString("workspace_id")
      writer.writeUInt(workspaceID)
      writer.writeString("status_json")
      if let statusJSON {
        writer.writeString(statusJSON)
      } else {
        writer.writeNil()
      }
    case .selectSpace(let index):
      writer.writeMapHeader(2)
      writer.writeString("name")
      writer.writeString("select-space")
      writer.writeString("index")
      writer.writeUInt(UInt64(index))
    case .selectTabInPanel(let panelID, let index):
      writer.writeMapHeader(3)
      writer.writeString("name")
      writer.writeString("select-tab-in-panel")
      writer.writeString("panel_id")
      writer.writeUInt(panelID)
      writer.writeString("index")
      writer.writeUInt(UInt64(index))
    case .moveTabToPanel(let fromPanelID, let from, let toPanelID, let to, let focus):
      writer.writeMapHeader(6)
      writer.writeString("name")
      writer.writeString("move-tab-to-panel")
      writer.writeString("from_panel_id")
      writer.writeUInt(fromPanelID)
      writer.writeString("from")
      writer.writeUInt(UInt64(from))
      writer.writeString("to_panel_id")
      writer.writeUInt(toPanelID)
      writer.writeString("to")
      writer.writeUInt(UInt64(to))
      writer.writeString("focus")
      writer.writeBool(focus)
    case .moveTabToSplit(let fromPanelID, let from, let targetPanelID, let edge, let focus):
      writer.writeMapHeader(6)
      writer.writeString("name")
      writer.writeString("move-tab-to-split")
      writer.writeString("from_panel_id")
      writer.writeUInt(fromPanelID)
      writer.writeString("from")
      writer.writeUInt(UInt64(from))
      writer.writeString("target_panel_id")
      writer.writeUInt(targetPanelID)
      writer.writeString("edge")
      writer.writeString(edge.rawValue)
      writer.writeString("focus")
      writer.writeBool(focus)
    case .setTabTitleByID(let tabID, let title, let explicit):
      writer.writeMapHeader(4)
      writer.writeString("name")
      writer.writeString("set-tab-title-by-id")
      writer.writeString("tab_id")
      writer.writeUInt(tabID)
      writer.writeString("title")
      if let title {
        writer.writeString(title)
      } else {
        writer.writeNil()
      }
      writer.writeString("explicit")
      writer.writeBool(explicit)
    case .focusPanel(let panelID):
      writer.writeMapHeader(2)
      writer.writeString("name")
      writer.writeString("focus-panel")
      writer.writeString("panel_id")
      writer.writeUInt(panelID)
    case .setWorkspacePinned(let workspaceID, let pinned):
      writer.writeMapHeader(3)
      writer.writeString("name")
      writer.writeString("set-workspace-pinned")
      writer.writeString("workspace_id")
      writer.writeUInt(workspaceID)
      writer.writeString("pinned")
      writer.writeBool(pinned)
    case .setWorkspaceUnread(let workspaceID, let unread):
      writer.writeMapHeader(3)
      writer.writeString("name")
      writer.writeString("set-workspace-unread")
      writer.writeString("workspace_id")
      writer.writeUInt(workspaceID)
      writer.writeString("unread")
      writer.writeBool(unread)
    case .setWorkspaceDescriptionByID(let workspaceID, let description):
      writer.writeMapHeader(3)
      writer.writeString("name")
      writer.writeString("set-workspace-description-by-id")
      writer.writeString("workspace_id")
      writer.writeUInt(workspaceID)
      writer.writeString("description")
      if let description {
        writer.writeString(description)
      } else {
        writer.writeNil()
      }
    case .setWorkspaceColorByID(let workspaceID, let color):
      writer.writeMapHeader(3)
      writer.writeString("name")
      writer.writeString("set-workspace-color-by-id")
      writer.writeString("workspace_id")
      writer.writeUInt(workspaceID)
      writer.writeString("color")
      if let color {
        writer.writeString(color)
      } else {
        writer.writeNil()
      }
    }
  }

  private static func writeTerminalSeedCommand(
    name: String,
    cwd: String?,
    initialInput: String?,
    to writer: inout MessagePackWriter
  ) {
    let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasCwd = cwd?.isEmpty == false
    let hasInitialInput = initialInput?.isEmpty == false
    writer.writeMapHeader(1 + (hasCwd ? 1 : 0) + (hasInitialInput ? 1 : 0))
    writer.writeString("name")
    writer.writeString(name)
    if hasCwd, let cwd {
      writer.writeString("cwd")
      writer.writeString(cwd)
    }
    if hasInitialInput, let initialInput {
      writer.writeString("initial_input")
      writer.writeString(initialInput)
    }
  }

  private static func requiredString(_ map: [String: MessagePackValue], _ key: String) throws
    -> String
  {
    guard let value = map[key] else {
      throw CmxWireError.invalidMessage("Missing \(key).")
    }
    return try value.stringValue()
  }

  private static func requiredData(_ map: [String: MessagePackValue], _ key: String) throws -> Data
  {
    guard let value = map[key] else {
      throw CmxWireError.invalidMessage("Missing \(key).")
    }
    return try value.dataValue()
  }

  private static func requiredUInt(_ map: [String: MessagePackValue], _ key: String) throws
    -> UInt64
  {
    guard let value = map[key] else {
      throw CmxWireError.invalidMessage("Missing \(key).")
    }
    return try value.uintValue()
  }

  private static func requiredInt(_ map: [String: MessagePackValue], _ key: String) throws -> Int {
    try checkedInt(try requiredUInt(map, key), key: key)
  }

  private static func requiredDouble(_ map: [String: MessagePackValue], _ key: String) throws
    -> Double
  {
    guard let value = map[key] else {
      throw CmxWireError.invalidMessage("Missing \(key).")
    }
    return try value.doubleValue()
  }

  private static func requiredBool(_ map: [String: MessagePackValue], _ key: String) throws -> Bool
  {
    guard let value = map[key] else {
      throw CmxWireError.invalidMessage("Missing \(key).")
    }
    return try value.boolValue()
  }

  private static func requiredMap(_ map: [String: MessagePackValue], _ key: String) throws
    -> [String: MessagePackValue]
  {
    guard let value = map[key] else {
      throw CmxWireError.invalidMessage("Missing \(key).")
    }
    return try value.mapValue()
  }

  private static func requiredArray(_ map: [String: MessagePackValue], _ key: String) throws
    -> [MessagePackValue]
  {
    guard let value = map[key] else {
      throw CmxWireError.invalidMessage("Missing \(key).")
    }
    return try value.arrayValue()
  }

  private static func optionalString(_ map: [String: MessagePackValue], _ key: String) throws
    -> String?
  {
    guard let value = map[key], value != .nilValue else { return nil }
    return try value.stringValue()
  }

  private static func optionalBool(
    _ map: [String: MessagePackValue], _ key: String, default defaultValue: Bool
  ) throws -> Bool {
    guard let value = map[key], value != .nilValue else { return defaultValue }
    return try value.boolValue()
  }

  private static func optionalUInt(
    _ map: [String: MessagePackValue], _ key: String, default defaultValue: UInt64
  ) throws -> UInt64 {
    guard let value = map[key], value != .nilValue else { return defaultValue }
    return try value.uintValue()
  }

  private static func optionalUInt(_ map: [String: MessagePackValue], _ key: String) throws
    -> UInt64?
  {
    guard let value = map[key], value != .nilValue else { return nil }
    return try value.uintValue()
  }

  private static func optionalInt(
    _ map: [String: MessagePackValue], _ key: String, default defaultValue: Int
  ) throws -> Int {
    guard let value = map[key], value != .nilValue else { return defaultValue }
    return try checkedInt(try value.uintValue(), key: key)
  }

  private static func optionalSignedInt(
    _ map: [String: MessagePackValue], _ key: String, default defaultValue: Int
  ) throws -> Int {
    guard let value = map[key], value != .nilValue else { return defaultValue }
    return try checkedSignedInt(try value.intValue(), key: key)
  }

  private static func checkedInt(_ value: UInt64, key: String) throws -> Int {
    guard value <= UInt64(Int.max) else {
      throw CmxWireError.invalidMessage("\(key) is out of range.")
    }
    return Int(value)
  }

  private static func checkedSignedInt(_ value: Int64, key: String) throws -> Int {
    guard value >= Int64(Int.min), value <= Int64(Int.max) else {
      throw CmxWireError.invalidMessage("\(key) is out of range.")
    }
    return Int(value)
  }

  private static func optionalMap(_ map: [String: MessagePackValue], _ key: String) throws
    -> [String: MessagePackValue]?
  {
    guard let value = map[key], value != .nilValue else { return nil }
    return try value.mapValue()
  }

  private static func optionalStringArray(_ map: [String: MessagePackValue], _ key: String) throws
    -> [String]
  {
    guard let value = map[key], value != .nilValue else { return [] }
    return try value.arrayValue().map { try $0.stringValue() }
  }

  private static func optionalArray(_ map: [String: MessagePackValue], _ key: String) throws
    -> [MessagePackValue]
  {
    guard let value = map[key], value != .nilValue else { return [] }
    return try value.arrayValue()
  }

  private static func optionalUIntArray(_ map: [String: MessagePackValue], _ key: String) throws
    -> [UInt64]
  {
    guard let value = map[key], value != .nilValue else { return [] }
    return try value.arrayValue().map { try $0.uintValue() }
  }

  private static func decodeNativeSnapshot(_ map: [String: MessagePackValue]) throws
    -> CmxNativeSnapshot
  {
    CmxNativeSnapshot(
      revision: try optionalUInt(map, "revision", default: 0),
      windowID: try optionalString(map, "window_id"),
      nativeWindowIDs: try optionalStringArray(map, "native_window_ids"),
      workspaces: try requiredArray(map, "workspaces").map {
        try decodeWorkspaceInfo($0.mapValue())
      },
      activeWorkspace: try requiredInt(map, "active_workspace"),
      activeWorkspaceID: try requiredUInt(map, "active_workspace_id"),
      spaces: try requiredArray(map, "spaces").map { try decodeSpaceInfo($0.mapValue()) },
      activeSpace: try requiredInt(map, "active_space"),
      activeSpaceID: try requiredUInt(map, "active_space_id"),
      panels: try decodePanelNode(try requiredMap(map, "panels")),
      focusedPanelID: try requiredUInt(map, "focused_panel_id"),
      focusedTabID: try requiredUInt(map, "focused_tab_id"),
      attachedClients: try (map["attached_clients"]?.arrayValue() ?? []).map {
        try decodeAttachedClientInfo($0.mapValue())
      },
      terminalTheme: try optionalMap(map, "terminal_theme").map(decodeTerminalThemeSet),
      terminalFont: try optionalMap(map, "terminal_font").map(decodeTerminalFont),
      terminalCursor: try optionalMap(map, "terminal_cursor").map(decodeTerminalCursorConfig),
      browserFocusRequest: try optionalMap(map, "browser_focus_request").map(
        decodeBrowserFocusRequest)
    )
  }

  private static func decodeBrowserFocusRequest(_ map: [String: MessagePackValue]) throws
    -> CmxNativeBrowserFocusRequest
  {
    CmxNativeBrowserFocusRequest(
      tabID: try requiredUInt(map, "tab_id"),
      generation: try requiredUInt(map, "generation")
    )
  }

  private static func decodeAttachedClientInfo(_ map: [String: MessagePackValue]) throws
    -> CmxAttachedClientInfo
  {
    guard let kind = CmxAttachedClientKind(rawValue: try requiredString(map, "kind")) else {
      throw CmxWireError.invalidMessage("Unsupported attached client kind.")
    }
    let latency: UInt32?
    if let value = map["latency_ms"], value != .nilValue {
      latency = UInt32(clamping: try value.uintValue())
    } else {
      latency = nil
    }
    return CmxAttachedClientInfo(
      clientID: try requiredString(map, "client_id"),
      kind: kind,
      visibleTerminalCount: try optionalInt(map, "visible_terminal_count", default: 0),
      updatedAtMilliseconds: try optionalUInt(map, "updated_at_ms", default: 0),
      terminals: try (map["terminals"]?.arrayValue() ?? []).map {
        try decodeWireTerminalViewport($0.mapValue())
      },
      latencyMilliseconds: latency
    )
  }

  private static func decodeWireTerminalViewport(_ map: [String: MessagePackValue]) throws
    -> CmxWireTerminalViewport
  {
    CmxWireTerminalViewport(
      tabID: try requiredUInt(map, "tab_id"),
      cols: UInt16(clamping: try requiredUInt(map, "cols")),
      rows: UInt16(clamping: try requiredUInt(map, "rows"))
    )
  }

  private static func decodeWorkspaceInfo(_ map: [String: MessagePackValue]) throws
    -> CmxNativeWorkspaceInfo
  {
    CmxNativeWorkspaceInfo(
      id: try requiredUInt(map, "id"),
      externalID: try optionalString(map, "external_id").flatMap(UUID.init(uuidString:)),
      title: try requiredString(map, "title"),
      description: try optionalString(map, "description"),
      latestSubmittedMessage: try optionalString(map, "latest_submitted_message"),
      spaceCount: try optionalInt(map, "space_count", default: 0),
      tabCount: try optionalInt(map, "tab_count", default: 0),
      terminalCount: try optionalInt(map, "terminal_count", default: 0),
      pinned: try optionalBool(map, "pinned", default: false),
      hasActivity: try optionalBool(map, "has_activity", default: false),
      bellCount: try optionalUInt(map, "bell_count", default: 0),
      color: try optionalString(map, "color"),
      statusEntries: try optionalArray(map, "status_entries").map {
        try decodeSidebarStatusEntry($0.mapValue())
      },
      metadataBlocks: try optionalArray(map, "metadata_blocks").map {
        try decodeSidebarMetadataBlock($0.mapValue())
      },
      logEntries: try optionalArray(map, "log_entries").map {
        try decodeSidebarLogEntry($0.mapValue())
      },
      progress: try optionalMap(map, "progress").map(decodeSidebarProgressState)
    )
  }

  private static func decodeSidebarStatusEntry(_ map: [String: MessagePackValue]) throws
    -> CmxNativeSidebarStatusEntry
  {
    CmxNativeSidebarStatusEntry(
      key: try requiredString(map, "key"),
      value: try requiredString(map, "value"),
      icon: try optionalString(map, "icon"),
      color: try optionalString(map, "color"),
      url: try optionalString(map, "url"),
      priority: try optionalSignedInt(map, "priority", default: 0),
      format: try optionalString(map, "format") ?? "plain",
      updatedAtMilliseconds: try optionalUInt(map, "updated_at_ms", default: 0)
    )
  }

  private static func decodeSidebarMetadataBlock(_ map: [String: MessagePackValue]) throws
    -> CmxNativeSidebarMetadataBlock
  {
    CmxNativeSidebarMetadataBlock(
      key: try requiredString(map, "key"),
      markdown: try requiredString(map, "markdown"),
      priority: try optionalSignedInt(map, "priority", default: 0),
      updatedAtMilliseconds: try optionalUInt(map, "updated_at_ms", default: 0)
    )
  }

  private static func decodeSidebarLogEntry(_ map: [String: MessagePackValue]) throws
    -> CmxNativeSidebarLogEntry
  {
    CmxNativeSidebarLogEntry(
      message: try requiredString(map, "message"),
      level: try optionalString(map, "level") ?? "info",
      source: try optionalString(map, "source"),
      updatedAtMilliseconds: try optionalUInt(map, "updated_at_ms", default: 0)
    )
  }

  private static func decodeSidebarProgressState(_ map: [String: MessagePackValue]) throws
    -> CmxNativeSidebarProgressState
  {
    CmxNativeSidebarProgressState(
      value: try requiredDouble(map, "value"),
      label: try optionalString(map, "label")
    )
  }

  private static func decodeSpaceInfo(_ map: [String: MessagePackValue]) throws
    -> CmxNativeSpaceInfo
  {
    CmxNativeSpaceInfo(
      id: try requiredUInt(map, "id"),
      title: try requiredString(map, "title"),
      paneCount: try optionalInt(map, "pane_count", default: 0),
      terminalCount: try optionalInt(map, "terminal_count", default: 0)
    )
  }

  private static func decodeTabInfo(_ map: [String: MessagePackValue]) throws -> CmxNativeTabInfo {
    let kindString = try optionalString(map, "kind") ?? CmxNativeTabKind.terminal.rawValue
    guard let kind = CmxNativeTabKind(rawValue: kindString) else {
      throw CmxWireError.invalidMessage("Unsupported native tab kind \(kindString).")
    }
    return CmxNativeTabInfo(
      id: try requiredUInt(map, "id"),
      externalID: try optionalString(map, "external_id").flatMap(UUID.init(uuidString:)),
      kind: kind,
      title: try requiredString(map, "title"),
      explicitTitle: try optionalBool(map, "explicit_title", default: false),
      pinned: try optionalBool(map, "pinned", default: false),
      hasActivity: try optionalBool(map, "has_activity", default: false),
      bellCount: try optionalUInt(map, "bell_count", default: 0),
      cwd: try optionalString(map, "cwd"),
      gitBranch: try optionalMap(map, "git_branch").map(decodeGitBranchInfo),
      pullRequest: try optionalMap(map, "pull_request").map(decodePullRequestInfo),
      ttyName: try optionalString(map, "tty_name"),
      shellState: try optionalString(map, "shell_state"),
      portsKickGeneration: try optionalUInt(map, "ports_kick_generation", default: 0),
      listeningPorts: try optionalUIntArray(map, "listening_ports").map {
        try checkedInt($0, key: "listening_ports")
      },
      browser: try optionalMap(map, "browser").map(decodeBrowserInfo)
    )
  }

  private static func decodeGitBranchInfo(_ map: [String: MessagePackValue]) throws
    -> CmxNativeGitBranchInfo
  {
    CmxNativeGitBranchInfo(
      branch: try requiredString(map, "branch"),
      isDirty: try optionalBool(map, "is_dirty", default: false)
    )
  }

  private static func decodePullRequestInfo(_ map: [String: MessagePackValue]) throws
    -> CmxNativePullRequestInfo
  {
    CmxNativePullRequestInfo(
      number: try checkedInt(try requiredUInt(map, "number"), key: "number"),
      label: try requiredString(map, "label"),
      urlString: try requiredString(map, "url"),
      status: try requiredString(map, "status"),
      branch: try optionalString(map, "branch"),
      isStale: try optionalBool(map, "is_stale", default: false)
    )
  }

  private static func decodeBrowserInfo(_ map: [String: MessagePackValue]) throws
    -> CmxNativeBrowserInfo
  {
    CmxNativeBrowserInfo(
      urlString: try optionalString(map, "url"),
      title: try optionalString(map, "title"),
      profileID: try optionalString(map, "profile_id"),
      shouldRenderWebView: try optionalBool(map, "should_render_webview", default: false),
      pageZoom: try optionalDouble(map, "page_zoom"),
      developerToolsVisible: try optionalBool(map, "developer_tools_visible", default: false),
      backHistoryURLStrings: try optionalStringArray(map, "back_history_url_strings"),
      forwardHistoryURLStrings: try optionalStringArray(map, "forward_history_url_strings"),
      proxy: try optionalMap(map, "proxy").map(decodeBrowserProxyContext),
      reloadGeneration: try optionalUInt(map, "reload_generation", default: 0)
    )
  }

  private static func decodeBrowserProxyContext(_ map: [String: MessagePackValue]) throws
    -> CmxNativeBrowserProxyContext
  {
    CmxNativeBrowserProxyContext(
      host: try requiredString(map, "host"),
      port: UInt16(clamping: try requiredUInt(map, "port")),
      target: try optionalString(map, "target")
    )
  }

  private static func decodePanelNode(_ map: [String: MessagePackValue]) throws
    -> CmxNativePanelNode
  {
    let kind = try requiredString(map, "kind")
    switch kind {
    case "leaf":
      return .leaf(
        panelID: try requiredUInt(map, "panel_id"),
        tabs: try requiredArray(map, "tabs").map { try decodeTabInfo($0.mapValue()) },
        active: try requiredInt(map, "active"),
        activeTabID: try requiredUInt(map, "active_tab_id")
      )
    case "split":
      let directionString = try requiredString(map, "direction")
      guard let direction = CmxNativeSplitDirection(rawValue: directionString) else {
        throw CmxWireError.invalidMessage("Unsupported native split direction \(directionString).")
      }
      return .split(
        direction: direction,
        ratioPermille: UInt16(clamping: try requiredUInt(map, "ratio_permille")),
        first: try decodePanelNode(try requiredMap(map, "first")),
        second: try decodePanelNode(try requiredMap(map, "second"))
      )
    default:
      throw CmxWireError.invalidMessage("Unsupported native panel node kind \(kind).")
    }
  }

  private static func decodeTerminalGridSnapshot(_ map: [String: MessagePackValue]) throws
    -> CmxNativeTerminalGridSnapshot
  {
    CmxNativeTerminalGridSnapshot(
      tabID: try requiredUInt(map, "tab_id"),
      cols: UInt16(clamping: try requiredUInt(map, "cols")),
      rows: UInt16(clamping: try requiredUInt(map, "rows")),
      cells: try requiredArray(map, "cells").map { try decodeTerminalGridCell($0.mapValue()) },
      cursor: try optionalMap(map, "cursor").map(decodeTerminalCursor)
    )
  }

  private static func decodeTerminalGridCell(_ map: [String: MessagePackValue]) throws
    -> CmxNativeTerminalGridCell
  {
    CmxNativeTerminalGridCell(
      text: try requiredString(map, "text"),
      width: UInt8(clamping: try requiredUInt(map, "width")),
      fg: try decodeRGB(try requiredMap(map, "fg")),
      bg: try decodeRGB(try requiredMap(map, "bg")),
      bold: try requiredBool(map, "bold"),
      italic: try requiredBool(map, "italic"),
      underline: try requiredBool(map, "underline"),
      faint: try requiredBool(map, "faint"),
      blink: try requiredBool(map, "blink"),
      strikethrough: try requiredBool(map, "strikethrough")
    )
  }

  private static func decodeTerminalCursor(_ map: [String: MessagePackValue]) throws
    -> CmxNativeTerminalCursorPosition
  {
    let styleString = try requiredString(map, "style")
    guard let style = CmxNativeTerminalCursorStyle(rawValue: styleString) else {
      throw CmxWireError.invalidMessage("Unsupported native cursor style \(styleString).")
    }
    return CmxNativeTerminalCursorPosition(
      col: UInt16(clamping: try requiredUInt(map, "col")),
      row: UInt16(clamping: try requiredUInt(map, "row")),
      visible: try requiredBool(map, "visible"),
      style: style,
      blink: try optionalBool(map, "blink", default: true),
      color: try optionalMap(map, "color").map(decodeRGB)
    )
  }

  private static func decodeRGB(_ map: [String: MessagePackValue]) throws -> CmxTerminalRGB {
    CmxTerminalRGB(
      r: UInt8(clamping: try requiredUInt(map, "r")),
      g: UInt8(clamping: try requiredUInt(map, "g")),
      b: UInt8(clamping: try requiredUInt(map, "b"))
    )
  }

  private static func decodeTerminalThemeSet(_ map: [String: MessagePackValue]) throws
    -> CmxNativeTerminalThemeSet
  {
    CmxNativeTerminalThemeSet(
      defaultTheme: try optionalMap(map, "default").map(decodeTerminalTheme),
      light: try optionalMap(map, "light").map(decodeTerminalTheme),
      dark: try optionalMap(map, "dark").map(decodeTerminalTheme)
    )
  }

  private static func decodeTerminalTheme(_ map: [String: MessagePackValue]) throws
    -> CmxNativeTerminalTheme
  {
    CmxNativeTerminalTheme(
      palette: try decodeTerminalPalette(try optionalMap(map, "palette") ?? [:]),
      foreground: try optionalString(map, "foreground"),
      background: try optionalString(map, "background"),
      cursor: try optionalString(map, "cursor"),
      cursorAccent: try optionalString(map, "cursor_accent"),
      selectionBackground: try optionalString(map, "selection_background"),
      selectionForeground: try optionalString(map, "selection_foreground"),
      black: try optionalString(map, "black"),
      red: try optionalString(map, "red"),
      green: try optionalString(map, "green"),
      yellow: try optionalString(map, "yellow"),
      blue: try optionalString(map, "blue"),
      magenta: try optionalString(map, "magenta"),
      cyan: try optionalString(map, "cyan"),
      white: try optionalString(map, "white"),
      brightBlack: try optionalString(map, "bright_black"),
      brightRed: try optionalString(map, "bright_red"),
      brightGreen: try optionalString(map, "bright_green"),
      brightYellow: try optionalString(map, "bright_yellow"),
      brightBlue: try optionalString(map, "bright_blue"),
      brightMagenta: try optionalString(map, "bright_magenta"),
      brightCyan: try optionalString(map, "bright_cyan"),
      brightWhite: try optionalString(map, "bright_white")
    )
  }

  private static func decodeTerminalPalette(_ map: [String: MessagePackValue]) throws -> [UInt8:
    String]
  {
    var palette: [UInt8: String] = [:]
    for (key, value) in map {
      guard let index = UInt8(key) else { continue }
      palette[index] = try value.stringValue()
    }
    return palette
  }

  private static func decodeTerminalFont(_ map: [String: MessagePackValue]) throws
    -> CmxNativeTerminalFont
  {
    let families = try (map["families"]?.arrayValue() ?? []).map { try $0.stringValue() }
    return CmxNativeTerminalFont(
      families: families,
      size: try optionalDouble(map, "size")
    )
  }

  private static func decodeTerminalCursorConfig(_ map: [String: MessagePackValue]) throws
    -> CmxNativeTerminalCursor
  {
    CmxNativeTerminalCursor(
      style: try optionalString(map, "style"),
      blink: try optionalBool(map, "blink")
    )
  }

  private static func optionalDouble(_ map: [String: MessagePackValue], _ key: String) throws
    -> Double?
  {
    guard let value = map[key], value != .nilValue else { return nil }
    return try value.doubleValue()
  }

  private static func optionalBool(_ map: [String: MessagePackValue], _ key: String) throws -> Bool?
  {
    guard let value = map[key], value != .nilValue else { return nil }
    return try value.boolValue()
  }
}

private enum MessagePackValue: Equatable {
  case nilValue
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case float(Double)
  case string(String)
  case binary(Data)
  case array([MessagePackValue])
  case map([String: MessagePackValue])

  func mapValue() throws -> [String: MessagePackValue] {
    guard case .map(let map) = self else { throw CmxWireError.expectedMap }
    return map
  }

  func arrayValue() throws -> [MessagePackValue] {
    guard case .array(let array) = self else {
      throw CmxWireError.invalidMessage("Expected MessagePack array.")
    }
    return array
  }

  func stringValue() throws -> String {
    guard case .string(let string) = self else { throw CmxWireError.expectedString }
    return string
  }

  func boolValue() throws -> Bool {
    guard case .bool(let bool) = self else {
      throw CmxWireError.invalidMessage("Expected MessagePack bool.")
    }
    return bool
  }

  func dataValue() throws -> Data {
    guard case .binary(let data) = self else { throw CmxWireError.expectedData }
    return data
  }

  func uintValue() throws -> UInt64 {
    switch self {
    case .uint(let value):
      return value
    case .int(let value) where value >= 0:
      return UInt64(value)
    default:
      throw CmxWireError.expectedInteger
    }
  }

  func intValue() throws -> Int64 {
    switch self {
    case .int(let value):
      return value
    case .uint(let value) where value <= UInt64(Int64.max):
      return Int64(value)
    default:
      throw CmxWireError.expectedInteger
    }
  }

  func doubleValue() throws -> Double {
    switch self {
    case .float(let value):
      return value
    case .uint(let value):
      return Double(value)
    case .int(let value):
      return Double(value)
    default:
      throw CmxWireError.invalidMessage("Expected MessagePack number.")
    }
  }

  var stringMapKey: String? {
    switch self {
    case .string(let value):
      return value
    case .uint(let value):
      return String(value)
    case .int(let value) where value >= 0:
      return String(value)
    default:
      return nil
    }
  }
}

public struct MessagePackWriter {
  private(set) var data = Data()

  mutating func writeNil() {
    data.append(0xC0)
  }

  mutating func writeBool(_ value: Bool) {
    data.append(value ? 0xC3 : 0xC2)
  }

  mutating func writeUInt(_ value: UInt64) {
    switch value {
    case 0...0x7F:
      data.append(UInt8(value))
    case 0x80...0xFF:
      data.append(0xCC)
      data.append(UInt8(value))
    case 0x100...0xFFFF:
      data.append(0xCD)
      appendBigEndian(UInt16(value))
    case 0x1_0000...0xFFFF_FFFF:
      data.append(0xCE)
      appendBigEndian(UInt32(value))
    default:
      data.append(0xCF)
      appendBigEndian(value)
    }
  }

  mutating func writeFloat64(_ value: Double) {
    data.append(0xCB)
    appendBigEndian(value.bitPattern)
  }

  mutating func writeString(_ string: String) {
    let bytes = Array(string.utf8)
    let count = bytes.count
    switch count {
    case 0...31:
      data.append(0xA0 | UInt8(count))
    case 32...0xFF:
      data.append(0xD9)
      data.append(UInt8(count))
    case 0x100...0xFFFF:
      data.append(0xDA)
      appendBigEndian(UInt16(count))
    default:
      data.append(0xDB)
      appendBigEndian(UInt32(count))
    }
    data.append(contentsOf: bytes)
  }

  mutating func writeBinary(_ binary: Data) {
    let count = binary.count
    switch count {
    case 0...0xFF:
      data.append(0xC4)
      data.append(UInt8(count))
    case 0x100...0xFFFF:
      data.append(0xC5)
      appendBigEndian(UInt16(count))
    default:
      data.append(0xC6)
      appendBigEndian(UInt32(count))
    }
    data.append(binary)
  }

  mutating func writeArrayHeader(_ count: Int) {
    switch count {
    case 0...15:
      data.append(0x90 | UInt8(count))
    case 16...0xFFFF:
      data.append(0xDC)
      appendBigEndian(UInt16(count))
    default:
      data.append(0xDD)
      appendBigEndian(UInt32(count))
    }
  }

  mutating func writeMapHeader(_ count: Int) {
    switch count {
    case 0...15:
      data.append(0x80 | UInt8(count))
    case 16...0xFFFF:
      data.append(0xDE)
      appendBigEndian(UInt16(count))
    default:
      data.append(0xDF)
      appendBigEndian(UInt32(count))
    }
  }

  private mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
  }
}

private struct MessagePackReader {
  let data: Data
  private var offset = 0

  var isAtEnd: Bool {
    offset == data.count
  }

  init(data: Data) {
    self.data = data
  }

  mutating func readValue() throws -> MessagePackValue {
    let byte = try readByte()
    switch byte {
    case 0x00...0x7F:
      return .uint(UInt64(byte))
    case 0x80...0x8F:
      return try readMap(count: Int(byte & 0x0F))
    case 0x90...0x9F:
      return try readArray(count: Int(byte & 0x0F))
    case 0xA0...0xBF:
      return try readString(count: Int(byte & 0x1F))
    case 0xC0:
      return .nilValue
    case 0xC2:
      return .bool(false)
    case 0xC3:
      return .bool(true)
    case 0xC4:
      return try readBinary(count: Int(readByte()))
    case 0xC5:
      return try readBinary(count: Int(readUInt16()))
    case 0xC6:
      return try readBinary(count: Int(readUInt32()))
    case 0xCA:
      return .float(Double(Float32(bitPattern: try readUInt32())))
    case 0xCB:
      return .float(Double(bitPattern: try readUInt64()))
    case 0xCC:
      return .uint(UInt64(try readByte()))
    case 0xCD:
      return .uint(UInt64(try readUInt16()))
    case 0xCE:
      return .uint(UInt64(try readUInt32()))
    case 0xCF:
      return .uint(try readUInt64())
    case 0xD0:
      return .int(Int64(Int8(bitPattern: try readByte())))
    case 0xD1:
      return .int(Int64(Int16(bitPattern: try readUInt16())))
    case 0xD2:
      return .int(Int64(Int32(bitPattern: try readUInt32())))
    case 0xD3:
      return .int(Int64(bitPattern: try readUInt64()))
    case 0xD9:
      return try readString(count: Int(readByte()))
    case 0xDA:
      return try readString(count: Int(readUInt16()))
    case 0xDB:
      return try readString(count: Int(readUInt32()))
    case 0xDC:
      return try readArray(count: Int(readUInt16()))
    case 0xDD:
      return try readArray(count: Int(readUInt32()))
    case 0xDE:
      return try readMap(count: Int(readUInt16()))
    case 0xDF:
      return try readMap(count: Int(readUInt32()))
    case 0xE0...0xFF:
      return .int(Int64(Int8(bitPattern: byte)))
    default:
      throw CmxWireError.unsupportedMessagePack(byte)
    }
  }

  private mutating func readMap(count: Int) throws -> MessagePackValue {
    guard count <= cmxMaxMessagePackCollectionCount else {
      throw CmxWireError.invalidMessage("MessagePack map is too large.")
    }
    var map: [String: MessagePackValue] = [:]
    map.reserveCapacity(count)
    for _ in 0..<count {
      let key = try readValue()
      let value = try readValue()
      if let stringKey = key.stringMapKey {
        map[stringKey] = value
      }
    }
    return .map(map)
  }

  private mutating func readArray(count: Int) throws -> MessagePackValue {
    guard count <= cmxMaxMessagePackCollectionCount else {
      throw CmxWireError.invalidMessage("MessagePack array is too large.")
    }
    var values: [MessagePackValue] = []
    values.reserveCapacity(count)
    for _ in 0..<count {
      values.append(try readValue())
    }
    return .array(values)
  }

  private mutating func readString(count: Int) throws -> MessagePackValue {
    let bytes = try readBytes(count)
    guard let string = String(data: bytes, encoding: .utf8) else {
      throw CmxWireError.invalidUTF8
    }
    return .string(string)
  }

  private mutating func readBinary(count: Int) throws -> MessagePackValue {
    .binary(try readBytes(count))
  }

  private mutating func readByte() throws -> UInt8 {
    guard offset < data.count else { throw CmxWireError.unexpectedEnd }
    defer { offset += 1 }
    return data[offset]
  }

  private mutating func readBytes(_ count: Int) throws -> Data {
    guard count >= 0, offset + count <= data.count else {
      throw CmxWireError.unexpectedEnd
    }
    defer { offset += count }
    return data.subdata(in: offset..<(offset + count))
  }

  private mutating func readUInt16() throws -> UInt16 {
    try readFixedWidthInteger()
  }

  private mutating func readUInt32() throws -> UInt32 {
    try readFixedWidthInteger()
  }

  private mutating func readUInt64() throws -> UInt64 {
    try readFixedWidthInteger()
  }

  private mutating func readFixedWidthInteger<T: FixedWidthInteger>() throws -> T {
    let bytes = try readBytes(MemoryLayout<T>.size)
    return bytes.reduce(T.zero) { partial, byte in
      (partial << 8) | T(byte)
    }
  }
}

extension CmxNativeSnapshot {
  public func ghosttyConfigFragment(colorPreference: CmxTerminalColorPreference) -> String? {
    var lines: [String] = []
    if let theme = terminalTheme?.effectiveTheme(colorPreference: colorPreference) {
      lines.append(contentsOf: theme.ghosttyConfigLines())
    }
    if let terminalFont {
      lines.append(contentsOf: terminalFont.ghosttyConfigLines())
    }
    if let terminalCursor {
      lines.append(contentsOf: terminalCursor.ghosttyConfigLines())
    }
    guard !lines.isEmpty else { return nil }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension CmxNativeTerminalTheme {
  public func ghosttyConfigLines() -> [String] {
    var lines: [String] = []
    appendColor("foreground", foreground, to: &lines)
    appendColor("background", background, to: &lines)
    appendColor("cursor-color", cursor, to: &lines)
    appendColor("cursor-text", cursorAccent, to: &lines)
    appendColor("selection-background", selectionBackground, to: &lines)
    appendColor("selection-foreground", selectionForeground, to: &lines)

    var resolvedPalette = palette
    for (index, value) in namedPaletteEntries {
      if let value {
        resolvedPalette[index] = value
      }
    }
    for index in resolvedPalette.keys.sorted() {
      guard let color = Self.sanitizedColor(resolvedPalette[index]) else { continue }
      lines.append("palette = \(index)=\(color)")
    }
    return lines
  }

  private var namedPaletteEntries: [(UInt8, String?)] {
    [
      (0, black),
      (1, red),
      (2, green),
      (3, yellow),
      (4, blue),
      (5, magenta),
      (6, cyan),
      (7, white),
      (8, brightBlack),
      (9, brightRed),
      (10, brightGreen),
      (11, brightYellow),
      (12, brightBlue),
      (13, brightMagenta),
      (14, brightCyan),
      (15, brightWhite),
    ]
  }

  private func appendColor(_ key: String, _ value: String?, to lines: inout [String]) {
    guard let color = Self.sanitizedColor(value) else { return }
    lines.append("\(key) = \(color)")
  }

  private static func sanitizedColor(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard hex.count == 3 || hex.count == 6 else { return nil }
    let hexScalars = Set("0123456789abcdefABCDEF".unicodeScalars)
    guard hex.unicodeScalars.allSatisfy({ hexScalars.contains($0) }) else { return nil }
    return "#\(hex)"
  }
}

extension CmxNativeTerminalFont {
  public func ghosttyConfigLines() -> [String] {
    var lines: [String] = []
    for family in families {
      let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
        !trimmed.contains(where: { $0.isNewline })
      else { continue }
      lines.append("font-family = \"\(trimmed.ghosttyEscapedString)\"")
    }
    if let size,
      size.isFinite,
      size > 0
    {
      lines.append(String(format: "font-size = %.3f", size))
    }
    return lines
  }
}

extension CmxNativeTerminalCursor {
  public func ghosttyConfigLines() -> [String] {
    var lines: [String] = []
    if let style,
      ["block", "bar", "underline", "block_hollow"].contains(style)
    {
      lines.append("cursor-style = \(style)")
    }
    if let blink {
      lines.append("cursor-style-blink = \(blink ? "true" : "false")")
    }
    return lines
  }
}

extension String {
  fileprivate var ghosttyEscapedString: String {
    replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
