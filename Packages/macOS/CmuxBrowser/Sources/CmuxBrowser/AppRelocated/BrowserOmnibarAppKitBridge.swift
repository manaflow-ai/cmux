// The omnibar AppKit bridge cluster moved to CmuxBrowserUI/Omnibar:
//
// - BrowserOmnibarNativeFieldRegistry (de-singletonized: the former process-wide
//   `static let shared` is gone; the browser-panel view constructs one instance
//   and injects it) -> CmuxBrowserUI/Omnibar/BrowserOmnibarNativeFieldRegistry.swift
// - BrowserOmnibarInteractionView + BrowserOmnibarInteractionRepresentable (now
//   carry the injected registry) -> CmuxBrowserUI/Omnibar/BrowserOmnibarInteractionView.swift
//
// This file is intentionally left as a moved-out marker; its pbxproj wiring is
// reconciled (and the file removed) by the orchestrator after the omnibar moves
// land.
