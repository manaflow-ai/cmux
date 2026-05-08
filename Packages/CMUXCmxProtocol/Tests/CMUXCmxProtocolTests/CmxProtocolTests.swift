import Foundation
import XCTest

@testable import CMUXCmxProtocol

final class CmxProtocolTests: XCTestCase {
  func testHelloEncodingMatchesCmxNamedMessagePackShape() throws {
    let payload = try CmxWireCodec.encode(
      .hello(viewport: CmxWireViewport(cols: 80, rows: 24), token: nil)
    )

    XCTAssertEqual(
      payload,
      Data([
        0x84,
        0xA4, 0x6B, 0x69, 0x6E, 0x64,
        0xA5, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
        0xA7, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E,
        0x03,
        0xA8, 0x76, 0x69, 0x65, 0x77, 0x70, 0x6F, 0x72, 0x74,
        0x82,
        0xA4, 0x63, 0x6F, 0x6C, 0x73,
        0x50,
        0xA4, 0x72, 0x6F, 0x77, 0x73,
        0x18,
        0xA5, 0x74, 0x6F, 0x6B, 0x65, 0x6E,
        0xC0,
      ]))
  }

  func testInputEncodingUsesMessagePackBinary() throws {
    let payload = try CmxWireCodec.encode(.input(Data("ok".utf8)))

    XCTAssertEqual(
      payload,
      Data([
        0x82,
        0xA4, 0x6B, 0x69, 0x6E, 0x64,
        0xA5, 0x69, 0x6E, 0x70, 0x75, 0x74,
        0xA4, 0x64, 0x61, 0x74, 0x61,
        0xC4, 0x02, 0x6F, 0x6B,
      ]))
  }

  func testHelloNativeRequestsClientSideLibghosttyRendering() throws {
    let payload = try CmxWireCodec.encode(
      .helloNative(
        viewport: CmxWireViewport(cols: 80, rows: 24),
        token: "sekrit",
        clientKind: .desktop,
        clientID: "client-a",
        windowID: "window-a",
        capabilities: [.libghosttyPtyBytes, .webviewWorker]
      )
    )

    XCTAssertNotNil(payload.range(of: Data("hello_native".utf8)))
    XCTAssertNotNil(payload.range(of: Data("terminal_renderer".utf8)))
    XCTAssertNotNil(payload.range(of: Data("libghostty".utf8)))
    XCTAssertNotNil(payload.range(of: Data("client_kind".utf8)))
    XCTAssertNotNil(payload.range(of: Data("desktop".utf8)))
    XCTAssertNotNil(payload.range(of: Data("client-a".utf8)))
    XCTAssertNotNil(payload.range(of: Data("window-a".utf8)))
    XCTAssertNotNil(payload.range(of: Data("libghostty_pty_bytes".utf8)))
    XCTAssertNotNil(payload.range(of: Data("webview_worker".utf8)))
  }

  func testCommandEncodingSelectsNativeTabInPanel() throws {
    let payload = try CmxWireCodec.encode(
      .command(id: 7, .selectTabInPanel(panelID: 31, index: 2))
    )

    XCTAssertNotNil(payload.range(of: Data("command".utf8)))
    XCTAssertNotNil(payload.range(of: Data("select-tab-in-panel".utf8)))
    XCTAssertNotNil(payload.range(of: Data("panel_id".utf8)))
    XCTAssertNotNil(payload.range(of: Data("index".utf8)))
  }

  func testCommandEncodingMovesTabToPanelWithExplicitFocus() throws {
    let payload = try CmxWireCodec.encode(
      .command(
        id: 8,
        .moveTabToPanel(fromPanelID: 31, from: 2, toPanelID: 41, to: 0, focus: false)
      )
    )

    XCTAssertNotNil(payload.range(of: Data("move-tab-to-panel".utf8)))
    XCTAssertNotNil(payload.range(of: Data("from_panel_id".utf8)))
    XCTAssertNotNil(payload.range(of: Data("to_panel_id".utf8)))
    XCTAssertNotNil(payload.range(of: Data("focus".utf8)))
    XCTAssertNotNil(payload.range(of: Data([0xC2])))
  }

  func testCommandEncodingMovesTabToSplitWithExplicitFocus() throws {
    let payload = try CmxWireCodec.encode(
      .command(
        id: 9,
        .moveTabToSplit(fromPanelID: 31, from: 2, targetPanelID: 41, edge: .left, focus: false)
      )
    )

    XCTAssertNotNil(payload.range(of: Data("move-tab-to-split".utf8)))
    XCTAssertNotNil(payload.range(of: Data("from_panel_id".utf8)))
    XCTAssertNotNil(payload.range(of: Data("target_panel_id".utf8)))
    XCTAssertNotNil(payload.range(of: Data("edge".utf8)))
    XCTAssertNotNil(payload.range(of: Data("left".utf8)))
    XCTAssertNotNil(payload.range(of: Data("focus".utf8)))
    XCTAssertNotNil(payload.range(of: Data([0xC2])))
  }

  func testCommandEncodingSetsTabTitleByStableID() throws {
    let rename = try CmxWireCodec.encode(
      .command(id: 10, .setTabTitleByID(tabID: 51, title: "Build Logs", explicit: true))
    )
    let clear = try CmxWireCodec.encode(
      .command(id: 11, .setTabTitleByID(tabID: 51, title: nil, explicit: false))
    )

    XCTAssertNotNil(rename.range(of: Data("set-tab-title-by-id".utf8)))
    XCTAssertNotNil(rename.range(of: Data("tab_id".utf8)))
    XCTAssertNotNil(rename.range(of: Data("Build Logs".utf8)))
    XCTAssertNotNil(rename.range(of: Data("explicit".utf8)))
    XCTAssertNotNil(rename.range(of: Data([0xC3])))
    XCTAssertNotNil(clear.range(of: Data("set-tab-title-by-id".utf8)))
    XCTAssertNotNil(clear.range(of: Data("title".utf8)))
    XCTAssertNotNil(clear.range(of: Data([0xC0])))
    XCTAssertNotNil(clear.range(of: Data([0xC2])))
  }

  func testCommandEncodingSetsWorkspacePinnedUnreadDescriptionAndColorState() throws {
    let pinned = try CmxWireCodec.encode(
      .command(id: 8, .setWorkspacePinned(workspaceID: 42, pinned: true))
    )
    let unread = try CmxWireCodec.encode(
      .command(id: 9, .setWorkspaceUnread(workspaceID: 42, unread: false))
    )
    let description = try CmxWireCodec.encode(
      .command(id: 10, .setWorkspaceDescriptionByID(workspaceID: 42, description: "Build queue"))
    )
    let color = try CmxWireCodec.encode(
      .command(id: 11, .setWorkspaceColorByID(workspaceID: 42, color: "#112233"))
    )

    XCTAssertNotNil(pinned.range(of: Data("set-workspace-pinned".utf8)))
    XCTAssertNotNil(pinned.range(of: Data("workspace_id".utf8)))
    XCTAssertNotNil(pinned.range(of: Data("pinned".utf8)))
    XCTAssertNotNil(unread.range(of: Data("set-workspace-unread".utf8)))
    XCTAssertNotNil(unread.range(of: Data("workspace_id".utf8)))
    XCTAssertNotNil(unread.range(of: Data("unread".utf8)))
    XCTAssertNotNil(description.range(of: Data("set-workspace-description-by-id".utf8)))
    XCTAssertNotNil(description.range(of: Data("workspace_id".utf8)))
    XCTAssertNotNil(description.range(of: Data("Build queue".utf8)))
    XCTAssertNotNil(color.range(of: Data("set-workspace-color-by-id".utf8)))
    XCTAssertNotNil(color.range(of: Data("workspace_id".utf8)))
    XCTAssertNotNil(color.range(of: Data("#112233".utf8)))
  }

  func testCommandEncodingTargetsWorkspaceByIDForCloseAndRename() throws {
    let close = try CmxWireCodec.encode(
      .command(id: 10, .closeWorkspaceByID(workspaceID: 42))
    )
    let rename = try CmxWireCodec.encode(
      .command(id: 11, .renameWorkspaceByID(workspaceID: 42, title: "Renamed"))
    )

    XCTAssertNotNil(close.range(of: Data("close-workspace-by-id".utf8)))
    XCTAssertNotNil(close.range(of: Data("workspace_id".utf8)))
    XCTAssertNotNil(rename.range(of: Data("rename-workspace-by-id".utf8)))
    XCTAssertNotNil(rename.range(of: Data("workspace_id".utf8)))
    XCTAssertNotNil(rename.range(of: Data("Renamed".utf8)))
  }

  func testPingEncodingKeepsNativeWebSocketClientAlive() throws {
    let payload = try CmxWireCodec.encode(.ping)

    XCTAssertEqual(
      payload,
      Data([
        0x81,
        0xA4, 0x6B, 0x69, 0x6E, 0x64,
        0xA4, 0x70, 0x69, 0x6E, 0x67,
      ]))
  }

  func testClientLatencyEncodingReportsMeasuredRoundTrip() throws {
    let payload = try CmxWireCodec.encode(.clientLatency(milliseconds: 42))

    XCTAssertNotNil(payload.range(of: Data("client_latency".utf8)))
    XCTAssertNotNil(payload.range(of: Data("latency_ms".utf8)))
    XCTAssertNotNil(payload.range(of: Data([42])))
  }

  func testDecodeWelcome() throws {
    let payload = Data([
      0x83,
      0xA4, 0x6B, 0x69, 0x6E, 0x64,
      0xA7, 0x77, 0x65, 0x6C, 0x63, 0x6F, 0x6D, 0x65,
      0xAE, 0x73, 0x65, 0x72, 0x76, 0x65, 0x72, 0x5F,
      0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E,
      0xA5, 0x30, 0x2E, 0x31, 0x2E, 0x30,
      0xAA, 0x73, 0x65, 0x73, 0x73, 0x69, 0x6F, 0x6E,
      0x5F, 0x69, 0x64,
      0xA3, 0x61, 0x62, 0x63,
    ])

    XCTAssertEqual(
      try CmxWireCodec.decodeServerMessage(payload),
      .welcome(serverVersion: "0.1.0", sessionID: "abc")
    )
  }

  func testDecodeCommandReplyIgnoresResultShape() throws {
    var writer = MessagePackWriter()
    writer.writeMapHeader(3)
    writer.writeString("kind")
    writer.writeString("command_reply")
    writer.writeString("id")
    writer.writeUInt(7)
    writer.writeString("result")
    writer.writeMapHeader(1)
    writer.writeString("ok")
    writer.writeBool(true)

    XCTAssertEqual(try CmxWireCodec.decodeServerMessage(writer.data), .commandReply(id: 7))
  }

  func testCompatibilityBridgeReplyEncoding() throws {
    let payload = try CmxWireCodec.encode(
      .nativeCompatibilityReply(
        requestID: 42,
        responseJSON: #"{"ok":true,"result":{"pong":true}}"#
      )
    )

    XCTAssertNotNil(payload.range(of: Data("native_compatibility_reply".utf8)))
    XCTAssertNotNil(payload.range(of: Data("request_id".utf8)))
    XCTAssertNotNil(payload.range(of: Data([42])))
    XCTAssertNotNil(payload.range(of: Data(#"{"ok":true,"result":{"pong":true}}"#.utf8)))
  }

  func testDecodeCompatibilityBridgeRequest() throws {
    var writer = MessagePackWriter()
    writer.writeMapHeader(3)
    writer.writeString("kind")
    writer.writeString("native_compatibility_request")
    writer.writeString("request_id")
    writer.writeUInt(7)
    writer.writeString("request_json")
    writer.writeString(#"{"id":1,"method":"browser.snapshot","params":{}}"#)

    XCTAssertEqual(
      try CmxWireCodec.decodeServerMessage(writer.data),
      .nativeCompatibilityRequest(
        requestID: 7,
        requestJSON: #"{"id":1,"method":"browser.snapshot","params":{}}"#
      )
    )
  }

  func testDesktopSessionImportRunsWhenSnapshotExistsButMarkerIsMissing() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let stateURL = rootURL.appendingPathComponent("cmx-state", isDirectory: true)
    try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

    let sourceURL = rootURL.appendingPathComponent("swift-session.json")
    try Data(#"{"version":1,"createdAt":1,"windows":[]}"#.utf8).write(to: sourceURL)
    let snapshotURL = stateURL.appendingPathComponent("snapshot.json")
    try Data(#"{"version":1}"#.utf8).write(to: snapshotURL)

    XCTAssertTrue(
      CmxDesktopDaemon.shouldImportDesktopSession(
        sourceURL: sourceURL,
        stateDirectory: stateURL
      )
    )
  }

  func testDesktopSessionImportSkipsWhenMarkerExists() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let stateURL = rootURL.appendingPathComponent("cmx-state", isDirectory: true)
    try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

    let sourceURL = rootURL.appendingPathComponent("swift-session.json")
    try Data(#"{"version":1,"createdAt":1,"windows":[]}"#.utf8).write(to: sourceURL)
    let markerURL = stateURL.appendingPathComponent("desktop-session-import.json")
    try Data(#"{"version":1,"status":"imported"}"#.utf8).write(to: markerURL)

    XCTAssertFalse(
      CmxDesktopDaemon.shouldImportDesktopSession(
        sourceURL: sourceURL,
        stateDirectory: stateURL
      )
    )
  }

  func testDecodePtyBytes() throws {
    let payload = Data([
      0x83,
      0xA4, 0x6B, 0x69, 0x6E, 0x64,
      0xA9, 0x70, 0x74, 0x79, 0x5F, 0x62, 0x79, 0x74, 0x65, 0x73,
      0xA6, 0x74, 0x61, 0x62, 0x5F, 0x69, 0x64,
      0x07,
      0xA4, 0x64, 0x61, 0x74, 0x61,
      0xC4, 0x02, 0x1B, 0x5B,
    ])

    XCTAssertEqual(
      try CmxWireCodec.decodeServerMessage(payload),
      .ptyBytes(tabID: 7, data: Data([0x1B, 0x5B]))
    )
  }

  func testDecodePtyBytesAcceptsOptionalSequence() throws {
    var writer = MessagePackWriter()
    writer.writeMapHeader(4)
    writer.writeString("kind")
    writer.writeString("pty_bytes")
    writer.writeString("tab_id")
    writer.writeUInt(7)
    writer.writeString("data")
    writer.writeBinary(Data([0x1B, 0x5B]))
    writer.writeString("seq")
    writer.writeUInt(99)

    XCTAssertEqual(
      try CmxWireCodec.decodeServerMessage(writer.data),
      .ptyBytes(tabID: 7, data: Data([0x1B, 0x5B]), seq: 99)
    )
  }

  func testDecodeRejectsOutOfRangeIntFields() {
    var writer = MessagePackWriter()
    writer.writeMapHeader(3)
    writer.writeString("kind")
    writer.writeString("active_tab_changed")
    writer.writeString("index")
    writer.writeUInt(UInt64.max)
    writer.writeString("tab_id")
    writer.writeUInt(1)

    XCTAssertThrowsError(try CmxWireCodec.decodeServerMessage(writer.data)) { error in
      XCTAssertEqual(error as? CmxWireError, .invalidMessage("index is out of range."))
    }
  }

  func testDecodeRejectsOversizedMessagePackCollectionsBeforeAllocating() {
    XCTAssertThrowsError(
      try CmxWireCodec.decodeServerMessage(Data([0xDD, 0xFF, 0xFF, 0xFF, 0xFF]))
    ) { error in
      XCTAssertEqual(error as? CmxWireError, .invalidMessage("MessagePack array is too large."))
    }
  }

  func testFramePrefixesBigEndianLength() throws {
    XCTAssertEqual(
      try CmxWireCodec.frame(Data([0x01, 0x02])),
      Data([0x00, 0x00, 0x00, 0x02, 0x01, 0x02])
    )
  }

  func testDecodeNativeSnapshot() throws {
    var writer = MessagePackWriter()
    writer.writeMapHeader(2)
    writer.writeString("kind")
    writer.writeString("native_snapshot")
    writer.writeString("snapshot")
    writeNativeSnapshot(to: &writer)

    let message = try CmxWireCodec.decodeServerMessage(writer.data)

    guard case .nativeSnapshot(let snapshot) = message else {
      return XCTFail("expected native snapshot, got \(message)")
    }
    XCTAssertEqual(snapshot.activeWorkspaceID, 11)
    XCTAssertEqual(snapshot.activeSpaceID, 21)
    XCTAssertEqual(snapshot.focusedPanelID, 31)
    XCTAssertEqual(snapshot.focusedTabID, 41)
    XCTAssertEqual(snapshot.workspaces.map(\.title), ["main", "agents"])
    XCTAssertEqual(
      snapshot.workspaces.first?.externalID,
      UUID(uuidString: "c0de0001-c0de-4000-8000-00000000000b"))
    XCTAssertEqual(snapshot.workspaces.first?.description, "Main workspace")
    XCTAssertEqual(snapshot.workspaces.first?.latestSubmittedMessage, "Build the prompt submit path")
    XCTAssertEqual(snapshot.workspaces.first?.statusEntries.first?.key, "build")
    XCTAssertEqual(snapshot.workspaces.first?.statusEntries.first?.priority, 2)
    XCTAssertEqual(snapshot.workspaces.first?.progress?.value, 0.5)
    XCTAssertEqual(snapshot.workspaces.first?.progress?.label, "Building")
    XCTAssertEqual(snapshot.workspaces.first?.logEntries.first?.message, "started")
    XCTAssertEqual(snapshot.spaces.map(\.title), ["space-a"])
    XCTAssertEqual(snapshot.panels.flattenedTabs.map(\.id), [41, 42])
    XCTAssertEqual(snapshot.panels.flattenedTabs.first?.cwd, "/tmp/cmx")
    XCTAssertEqual(
      snapshot.panels.flattenedTabs.first?.gitBranch,
      CmxNativeGitBranchInfo(branch: "main", isDirty: true))
    XCTAssertEqual(snapshot.panels.flattenedTabs.first?.pullRequest?.number, 42)
    XCTAssertEqual(snapshot.panels.flattenedTabs.first?.pullRequest?.status, "open")
    XCTAssertEqual(snapshot.panels.flattenedTabs.first?.ttyName, "ttys001")
    XCTAssertEqual(snapshot.panels.flattenedTabs.first?.shellState, "prompt")
    XCTAssertEqual(snapshot.panels.flattenedTabs.first?.portsKickGeneration, 3)
    XCTAssertEqual(snapshot.panels.flattenedTabs.first?.listeningPorts, [3000, 5173])
    XCTAssertEqual(
      snapshot.panels.flattenedTabs.map(\.externalID),
      [
        UUID(uuidString: "c0de0002-c0de-4000-8000-000000000029"),
        UUID(uuidString: "c0de0002-c0de-4000-8000-00000000002a"),
      ]
    )
    XCTAssertEqual(snapshot.panels.selection(for: 42), CmxNativeTabSelection(panelID: 31, index: 1))
    XCTAssertEqual(snapshot.terminalTheme?.defaultTheme?.palette[1], "#f92672")
    XCTAssertEqual(snapshot.terminalTheme?.defaultTheme?.background, "#272822")
    XCTAssertEqual(snapshot.terminalFont?.families, ["JetBrains Mono"])
    XCTAssertEqual(snapshot.terminalFont?.size, 13.0)
    XCTAssertEqual(snapshot.terminalCursor?.style, "block")
    XCTAssertEqual(snapshot.terminalCursor?.blink, true)
    XCTAssertEqual(snapshot.revision, 0)
    XCTAssertEqual(snapshot.attachedClients.first?.kind, .native)
    XCTAssertEqual(
      snapshot.attachedClients.first?.terminals.first,
      CmxWireTerminalViewport(tabID: 41, cols: 30, rows: 30))
    XCTAssertTrue(
      snapshot.ghosttyConfigFragment(colorPreference: .dark)?.contains("palette = 1=#f92672")
        == true)
    XCTAssertTrue(
      snapshot.ghosttyConfigFragment(colorPreference: .dark)?.contains("background = #272822")
        == true)
    XCTAssertTrue(
      snapshot.ghosttyConfigFragment(colorPreference: .dark)?.contains("cursor-style = block")
        == true)
    XCTAssertTrue(
      snapshot.ghosttyConfigFragment(colorPreference: .dark)?.contains("cursor-style-blink = true")
        == true)
  }

  func testDesktopRuntimePathsUseTagScopedStateAndShortSockets() {
    let paths = CmxDesktopRuntimePathResolver.resolve(
      tag: "desktop cmx/backend",
      homeDirectory: URL(fileURLWithPath: "/Users/example"),
      temporaryDirectory: URL(fileURLWithPath: "/tmp")
    )

    XCTAssertEqual(paths.stateDirectory.path, "/tmp/cmux-cmx-desktop-cmx-backend/cmx-state")
    XCTAssertEqual(paths.nativeSocketPath, "/tmp/cmux-cmx-desktop-cmx-backend/native.sock")
    XCTAssertEqual(paths.compatibilitySocketPath, "/tmp/cmux-debug-desktop-cmx-backend.sock")
  }

  @MainActor
  func testDesktopStoreAppliesAuthoritativeNativeSnapshot() throws {
    var writer = MessagePackWriter()
    writer.writeMapHeader(2)
    writer.writeString("kind")
    writer.writeString("native_snapshot")
    writer.writeString("snapshot")
    writeNativeSnapshot(to: &writer)

    let store = CmxDesktopStore()
    store.apply(try CmxWireCodec.decodeServerMessage(writer.data))

    XCTAssertEqual(store.snapshot?.focusedTabID, 41)
    XCTAssertNil(store.lastErrorMessage)

    store.apply(.error("boom"))
    XCTAssertEqual(store.lastErrorMessage, "boom")

    store.apply(.bye)
    XCTAssertTrue(store.isClosed)
  }

  func testCmxConnectionSendsHelloNativeAndStreamsMessages() async throws {
    let transport = ScriptedFrameTransport(receiveFrames: [
      serverPayload(
        kind: "welcome",
        fields: { writer in
          writer.writeString("server_version")
          writer.writeString("0.1.0")
          writer.writeString("session_id")
          writer.writeString("session-a")
        }),
      serverPayload(kind: "bye", fields: nil),
    ])
    let connection = CmxConnection(transport: transport)

    let stream = try await connection.connectNative(
      viewport: CmxWireViewport(cols: 80, rows: 24),
      clientID: "client-a",
      windowID: "window-a",
      capabilities: [.libghosttyPtyBytes, .webviewWorker]
    )

    let sent = await transport.sentFrames()
    XCTAssertEqual(sent.count, 1)
    XCTAssertNotNil(sent[0].range(of: Data("hello_native".utf8)))
    XCTAssertNotNil(sent[0].range(of: Data("client-a".utf8)))

    var received: [CmxServerMessage] = []
    for try await message in stream {
      received.append(message)
    }

    XCTAssertEqual(
      received,
      [
        .welcome(serverVersion: "0.1.0", sessionID: "session-a"),
        .bye,
      ])
  }

  func testDecodeTerminalGridSnapshot() throws {
    var writer = MessagePackWriter()
    writer.writeMapHeader(2)
    writer.writeString("kind")
    writer.writeString("terminal_grid_snapshot")
    writer.writeString("snapshot")
    writer.writeMapHeader(5)
    writer.writeString("tab_id")
    writer.writeUInt(41)
    writer.writeString("cols")
    writer.writeUInt(80)
    writer.writeString("rows")
    writer.writeUInt(24)
    writer.writeString("cells")
    writer.writeArrayHeader(1)
    writeCell(text: "A", to: &writer)
    writer.writeString("cursor")
    writer.writeMapHeader(6)
    writer.writeString("col")
    writer.writeUInt(1)
    writer.writeString("row")
    writer.writeUInt(2)
    writer.writeString("visible")
    writer.writeBool(true)
    writer.writeString("style")
    writer.writeString("bar")
    writer.writeString("blink")
    writer.writeBool(false)
    writer.writeString("color")
    writeRGB(255, 0, 0, to: &writer)

    let message = try CmxWireCodec.decodeServerMessage(writer.data)

    guard case .terminalGridSnapshot(let snapshot) = message else {
      return XCTFail("expected terminal grid snapshot, got \(message)")
    }
    XCTAssertEqual(snapshot.tabID, 41)
    XCTAssertEqual(snapshot.cells.first?.fg, CmxTerminalRGB(r: 1, g: 2, b: 3))
    XCTAssertEqual(snapshot.cursor?.style, .bar)
    XCTAssertEqual(snapshot.cursor?.blink, false)
    XCTAssertEqual(snapshot.cursor?.color, CmxTerminalRGB(r: 255, g: 0, b: 0))
  }

  private func writeNativeSnapshot(to writer: inout MessagePackWriter) {
    writer.writeMapHeader(14)
    writer.writeString("workspaces")
    writer.writeArrayHeader(2)
    writeWorkspace(id: 11, title: "main", spaces: 1, terminals: 2, pinned: true, to: &writer)
    writeWorkspace(id: 12, title: "agents", spaces: 0, terminals: 0, pinned: false, to: &writer)
    writer.writeString("active_workspace")
    writer.writeUInt(0)
    writer.writeString("active_workspace_id")
    writer.writeUInt(11)
    writer.writeString("spaces")
    writer.writeArrayHeader(1)
    writeSpace(id: 21, title: "space-a", to: &writer)
    writer.writeString("active_space")
    writer.writeUInt(0)
    writer.writeString("active_space_id")
    writer.writeUInt(21)
    writer.writeString("panels")
    writer.writeMapHeader(5)
    writer.writeString("kind")
    writer.writeString("leaf")
    writer.writeString("panel_id")
    writer.writeUInt(31)
    writer.writeString("tabs")
    writer.writeArrayHeader(2)
    writeTab(id: 41, title: "shell", active: false, to: &writer)
    writeTab(id: 42, title: "logs", active: true, to: &writer)
    writer.writeString("active")
    writer.writeUInt(0)
    writer.writeString("active_tab_id")
    writer.writeUInt(41)
    writer.writeString("focused_panel_id")
    writer.writeUInt(31)
    writer.writeString("focused_tab_id")
    writer.writeUInt(41)
    writer.writeString("terminal_theme")
    writer.writeMapHeader(1)
    writer.writeString("default")
    writer.writeMapHeader(2)
    writer.writeString("palette")
    writer.writeMapHeader(1)
    writer.writeUInt(1)
    writer.writeString("#f92672")
    writer.writeString("background")
    writer.writeString("#272822")
    writer.writeString("terminal_font")
    writer.writeMapHeader(2)
    writer.writeString("families")
    writer.writeArrayHeader(1)
    writer.writeString("JetBrains Mono")
    writer.writeString("size")
    writer.writeFloat64(13.0)
    writer.writeString("terminal_cursor")
    writer.writeMapHeader(2)
    writer.writeString("style")
    writer.writeString("block")
    writer.writeString("blink")
    writer.writeBool(true)
    writer.writeString("attached_clients")
    writer.writeArrayHeader(1)
    writer.writeMapHeader(6)
    writer.writeString("client_id")
    writer.writeString("ios")
    writer.writeString("kind")
    writer.writeString("native")
    writer.writeString("visible_terminal_count")
    writer.writeUInt(1)
    writer.writeString("updated_at_ms")
    writer.writeUInt(123)
    writer.writeString("terminals")
    writer.writeArrayHeader(1)
    writer.writeMapHeader(3)
    writer.writeString("tab_id")
    writer.writeUInt(41)
    writer.writeString("cols")
    writer.writeUInt(30)
    writer.writeString("rows")
    writer.writeUInt(30)
    writer.writeString("latency_ms")
    writer.writeUInt(2)
  }

  private func writeWorkspace(
    id: UInt64,
    title: String,
    spaces: UInt64,
    terminals: UInt64,
    pinned: Bool,
    to writer: inout MessagePackWriter
  ) {
    writer.writeMapHeader(13)
    writer.writeString("id")
    writer.writeUInt(id)
    writer.writeString("external_id")
    writer.writeString(String(format: "c0de0001-c0de-4000-8000-%012llx", CUnsignedLongLong(id)))
    writer.writeString("title")
    writer.writeString(title)
    writer.writeString("description")
    if id == 11 {
      writer.writeString("Main workspace")
    } else {
      writer.writeNil()
    }
    writer.writeString("latest_submitted_message")
    if id == 11 {
      writer.writeString("Build the prompt submit path")
    } else {
      writer.writeNil()
    }
    writer.writeString("space_count")
    writer.writeUInt(spaces)
    writer.writeString("tab_count")
    writer.writeUInt(terminals)
    writer.writeString("terminal_count")
    writer.writeUInt(terminals)
    writer.writeString("pinned")
    writer.writeBool(pinned)
    writer.writeString("color")
    writer.writeNil()
    writer.writeString("status_entries")
    if id == 11 {
      writer.writeArrayHeader(1)
      writer.writeMapHeader(8)
      writer.writeString("key")
      writer.writeString("build")
      writer.writeString("value")
      writer.writeString("compiling")
      writer.writeString("icon")
      writer.writeString("hammer")
      writer.writeString("color")
      writer.writeString("#00ff00")
      writer.writeString("url")
      writer.writeString("https://example.com")
      writer.writeString("priority")
      writer.writeUInt(2)
      writer.writeString("format")
      writer.writeString("plain")
      writer.writeString("updated_at_ms")
      writer.writeUInt(123)
    } else {
      writer.writeArrayHeader(0)
    }
    writer.writeString("metadata_blocks")
    writer.writeArrayHeader(0)
    writer.writeString("log_entries")
    if id == 11 {
      writer.writeArrayHeader(1)
      writer.writeMapHeader(4)
      writer.writeString("message")
      writer.writeString("started")
      writer.writeString("level")
      writer.writeString("info")
      writer.writeString("source")
      writer.writeNil()
      writer.writeString("updated_at_ms")
      writer.writeUInt(124)
    } else {
      writer.writeArrayHeader(0)
    }
    writer.writeString("progress")
    if id == 11 {
      writer.writeMapHeader(2)
      writer.writeString("value")
      writer.writeFloat64(0.5)
      writer.writeString("label")
      writer.writeString("Building")
    } else {
      writer.writeNil()
    }
  }

  private func writeSpace(id: UInt64, title: String, to writer: inout MessagePackWriter) {
    writer.writeMapHeader(5)
    writer.writeString("id")
    writer.writeUInt(id)
    writer.writeString("external_id")
    writer.writeString(String(format: "c0de0002-c0de-4000-8000-%012llx", CUnsignedLongLong(id)))
    writer.writeString("title")
    writer.writeString(title)
    writer.writeString("pane_count")
    writer.writeUInt(1)
    writer.writeString("terminal_count")
    writer.writeUInt(2)
  }

  private func writeTab(id: UInt64, title: String, active: Bool, to writer: inout MessagePackWriter)
  {
    writer.writeMapHeader(11)
    writer.writeString("id")
    writer.writeUInt(id)
    writer.writeString("title")
    writer.writeString(title)
    writer.writeString("has_activity")
    writer.writeBool(active)
    writer.writeString("bell_count")
    writer.writeUInt(active ? 1 : 0)
    writer.writeString("cwd")
    writer.writeString("/tmp/cmx")
    writer.writeString("git_branch")
    writer.writeMapHeader(2)
    writer.writeString("branch")
    writer.writeString("main")
    writer.writeString("is_dirty")
    writer.writeBool(true)
    writer.writeString("pull_request")
    writer.writeMapHeader(6)
    writer.writeString("number")
    writer.writeUInt(42)
    writer.writeString("label")
    writer.writeString("PR")
    writer.writeString("url")
    writer.writeString("https://example.com/pull/42")
    writer.writeString("status")
    writer.writeString("open")
    writer.writeString("branch")
    writer.writeString("main")
    writer.writeString("is_stale")
    writer.writeBool(false)
    writer.writeString("tty_name")
    writer.writeString("ttys001")
    writer.writeString("shell_state")
    writer.writeString("prompt")
    writer.writeString("ports_kick_generation")
    writer.writeUInt(3)
    writer.writeString("listening_ports")
    writer.writeArrayHeader(2)
    writer.writeUInt(3000)
    writer.writeUInt(5173)
  }

  private func writeCell(text: String, to writer: inout MessagePackWriter) {
    writer.writeMapHeader(10)
    writer.writeString("text")
    writer.writeString(text)
    writer.writeString("width")
    writer.writeUInt(1)
    writer.writeString("fg")
    writeRGB(1, 2, 3, to: &writer)
    writer.writeString("bg")
    writeRGB(4, 5, 6, to: &writer)
    writer.writeString("bold")
    writer.writeBool(true)
    writer.writeString("italic")
    writer.writeBool(false)
    writer.writeString("underline")
    writer.writeBool(false)
    writer.writeString("faint")
    writer.writeBool(false)
    writer.writeString("blink")
    writer.writeBool(false)
    writer.writeString("strikethrough")
    writer.writeBool(false)
  }

  private func writeRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8, to writer: inout MessagePackWriter) {
    writer.writeMapHeader(3)
    writer.writeString("r")
    writer.writeUInt(UInt64(r))
    writer.writeString("g")
    writer.writeUInt(UInt64(g))
    writer.writeString("b")
    writer.writeUInt(UInt64(b))
  }

  private func serverPayload(kind: String, fields: ((inout MessagePackWriter) -> Void)?) -> Data {
    var writer = MessagePackWriter()
    writer.writeMapHeader(fields == nil ? 1 : 3)
    writer.writeString("kind")
    writer.writeString(kind)
    fields?(&writer)
    return writer.data
  }
}

private actor ScriptedFrameTransport: CmxFrameTransport {
  private var receiveFrames: [Data]
  private var sent: [Data] = []

  init(receiveFrames: [Data]) {
    self.receiveFrames = receiveFrames
  }

  func open() async throws {}

  func sendFrame(_ payload: Data) async throws {
    sent.append(payload)
  }

  func receiveFrame() async throws -> Data? {
    guard !receiveFrames.isEmpty else {
      return nil
    }
    return receiveFrames.removeFirst()
  }

  func close() async {}

  func sentFrames() -> [Data] {
    sent
  }
}
