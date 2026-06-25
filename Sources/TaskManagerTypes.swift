// NOTE (refactor): every type formerly in this file has moved into packages.
//
// Domain package `CmuxTaskManager` (Packages/macOS/CmuxTaskManager,
// SwiftUI-free) now owns:
//   - `CmuxTaskManagerRow` (+ nested `Kind`) — CmuxTaskManagerRow.swift
//   - `CmuxTaskManagerSortOrder` (+ private `SortNode`) — CmuxTaskManagerSortOrder.swift
//   - the former `CmuxTaskManagerFormat` namespace, now value-typed:
//       * `Double.taskManagerCPUString` / `Int64.taskManagerByteString`
//         (CmuxTaskManagerNumberFormatting.swift)
//       * `CmuxTaskManagerDateFormatting` value type holding the cached
//         ISO8601/time formatters (CmuxTaskManagerDateFormatting.swift)
//
// Paired UI package `CmuxTaskManagerUI` (Packages/macOS/CmuxTaskManagerUI)
// owns the SwiftUI presentation of `CmuxTaskManagerRow.Kind`
// (`.systemImage` / `.tint`) as a `Kind+Presentation` extension, so the
// domain package stays SwiftUI-free.
//
// Consumers (app-target readers) updated this slice:
//   - TaskManagerSnapshot.swift  — uses CmuxTaskManagerRow + the date formatter
//   - TaskManagerView.swift      — uses Row/SortOrder + Kind presentation + number formatting
//   - TaskManagerWindowController.swift — uses Row/SortOrder
//
// FINAL INTEGRATION TODO (orchestrator): wire the cmux app target against
// `CmuxTaskManager` and `CmuxTaskManagerUI` (pbxproj + workspace groups).
// This file no longer declares any type and can be removed from the build
// once the imports above are wired.
