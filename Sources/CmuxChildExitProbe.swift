import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Child-exit keyboard probe (UI-test instrumentation)
#if DEBUG
private func cmuxChildExitProbePath() -> String? {
    let env = ProcessInfo.processInfo.environment
    guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
          let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
          !path.isEmpty else {
        return nil
    }
    return path
}

private func cmuxLoadChildExitProbe(at path: String) -> [String: String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return [:]
    }
    return object
}

func cmuxWriteChildExitProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
    guard let path = cmuxChildExitProbePath() else { return }
    var payload = cmuxLoadChildExitProbe(at: path)
    for (key, by) in increments {
        let current = Int(payload[key] ?? "") ?? 0
        payload[key] = String(current + by)
    }
    for (key, value) in updates {
        payload[key] = value
    }
    guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
    try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func cmuxScalarHex(_ value: String?) -> String {
    guard let value else { return "" }
    return value.unicodeScalars
        .map { String(format: "%04X", $0.value) }
        .joined(separator: ",")
}
#endif

