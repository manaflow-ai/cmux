// Printing a hosted page (plans/cmux-next/chrome-parity/p01-process.md,
// task p01-process-065). The host never shows Chromium's print preview (a
// host window): cmux asks for the page as a PDF, the host prints it with
// CefBrowserHost::PrintToPDF and hands the document back in a sealed shared
// memory region, and cmux runs the system print panel on that PDF in its own
// window. Chrome moves a printed document between processes the same way: the
// renderer's PDF reaches the browser as a base::ReadOnlySharedMemoryRegion
// (components/printing/common/print.mojom, DidPrintContentParams), never as
// inline bytes.
//
// The op is not in the generated table (as kOpEnergySaver, host_energy_saver.h):
//   cmux -> host  kOpPrintToPdf with a token:
//                 i32 version (kPrintToPdfVersion), then version 1's fields:
//                 i32 browser (cmux's id), f64 paper width, f64 paper height
//                 (inches, the print panel's paper; 0 x 0: Chromium's default)
//   host -> cmux  kOpReply for that token: i32 result (1 printed), i64 size;
//                 with result 1 the frame's one descriptor is the sealed region
//                 (CreateSharedRegion) holding `size` bytes of PDF.
// A later version only appends fields. A host lists kPrintToPdfHelloName in
// its HELLO when it prints; cmux sends the op to no other host.
//
// A print the page starts (window.print(), Chromium's print command on the
// page) would open the same preview. With cmux's panel on, the fork's print
// request hook stops it before the preview opens, the host hands it to cmux,
// and cmux prints the page as File > Print does (kOpPrintToPdf, then its
// panel). The page's window.print() returns when cmux ends the request, after
// the panel: Chrome holds it the same way until its preview closes
// (PrintViewManager::SetupScriptedPrintPreview keeps the renderer's reply until
// PrintPreviewDone, chrome/browser/printing/print_view_manager.cc).
//   cmux -> host  kOpPagePrints: i32 version (kPagePrintsVersion), i32 enabled
//                 (1: page prints go to cmux; 0: Chromium's preview again, and
//                 the waiting requests end)
//   cmux -> host  kOpPagePrintEnd: i32 version, i64 request: its panel ended,
//                 or none could show
//   host -> cmux  kOpEvent CMUX_SHIM_PAGE_PRINT (kEventPagePrint, an optional
//                 event of plans/cmux-next/chromium-host-ops.json):
//                 browser_id = the page (cmux's id), a = the request
// A host whose fork has the hook lists kPagePrintsHelloName in its HELLO;
// cmux sends neither op to another host.
//
// Fork item (after API 31, PL-cef-layer), in include/cef_cmux.h:
//   int cmux_set_print_request_handler(
//       void (*fn)(void* ctx, int browser_id, int64_t request),
//       void* ctx);  // NULL fn clears it; returns 1 when set
//   int cmux_print_request_end(int64_t request);  // 1 when it was waiting
// With fn set, a print a page starts opens no print preview: where
// PrintViewManager would open PrintPreviewDialogController's dialog
// (PrintPreviewNow), the fork calls fn on the UI thread with a new request
// and holds the page's scripted print until cmux_print_request_end(request);
// CefBrowserHost::PrintToPDF prints the page while it waits. A request ends
// with its page; ending it again returns 0.
//
// Plain C++, no CEF: the tests build it on Linux
// (scripts/cmux-next/tests/chromium-host-dispatch.test.sh). The printer that
// calls CEF is host_print.mm.
#pragma once

#include <cstdint>
#include <cstddef>
#include <functional>
#include <optional>
#include <unordered_map>
#include <vector>

#include "chromium_host_tlv.h"

namespace cmux_host {

// Not in the generated op table, as kOpEnergySaver (host_energy_saver.h); the
// task's number, clear of the ids the other host ops take in order.
inline constexpr uint16_t kOpPrintToPdf = 0x8065;
// The kOpPrintToPdf layout this side writes.
inline constexpr int32_t kPrintToPdfVersion = 1;
// The name a host that prints lists in its HELLO's exports.
inline constexpr char kPrintToPdfHelloName[] = "cmux_host_print_to_pdf";
// The largest paper side the op takes, in inches (Chromium's own bound is
// far larger; no printer paper is past this).
inline constexpr double kMaxPaperInches = 200;

// kOpPrintToPdf's fields.
struct PrintToPdf {
  int32_t browser = 0;
  double paper_width = 0;   // inches; 0 with paper_height 0: Chromium's default paper
  double paper_height = 0;

  bool operator==(const PrintToPdf& other) const = default;
};

// Writes kOpPrintToPdf's fields for `print` (the remote shim's side).
inline void WritePrintToPdf(const PrintToPdf& print, control::TlvWriter* w) {
  w->I32(kPrintToPdfVersion);
  w->I32(print.browser);
  w->F64(print.paper_width);
  w->F64(print.paper_height);
}

// The op's fields; nullopt for a malformed op (no version or one below 1,
// wrong types, a paper side that is negative, not finite or over
// kMaxPaperInches, one side 0 without the other, version 1 with more fields).
inline std::optional<PrintToPdf> DecodePrintToPdf(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t version = r.I32();
  PrintToPdf print;
  print.browser = r.I32();
  print.paper_width = r.F64();
  print.paper_height = r.F64();
  if (!r.ok() || version < 1) return std::nullopt;
  if (version == kPrintToPdfVersion && !r.AtEnd()) return std::nullopt;
  auto side_ok = [](double side) { return side >= 0 && side <= kMaxPaperInches; };  // false for NaN
  if (!side_ok(print.paper_width) || !side_ok(print.paper_height)) return std::nullopt;
  if ((print.paper_width == 0) != (print.paper_height == 0)) return std::nullopt;
  return print;
}

// Prints Chromium's browsers to PDF (host_print.mm: CefBrowserHost::PrintToPDF;
// the tests: a fake). Main thread only.
class PdfPrinter {
 public:
  // `fd`: a sealed region holding `size` bytes of PDF, which the callee owns
  // from here; -1 (size 0) when the page did not print.
  using Done = std::function<void(int fd, uint64_t size)>;

  virtual ~PdfPrinter() = default;
  // Prints browser `chromium_id` at `print`'s paper; `done` runs once, later,
  // on the main thread (or at once when the browser is gone).
  virtual void Print(int chromium_id, const PrintToPdf& print, Done done) = 0;
};

// The host's printer (host_print.mm): CefBrowserHost::PrintToPDF into a file
// of the host's temporary directory, as CEF prints only to a path
// (libcef/browser/printing/print_util.cc writes it on a blocking thread);
// that file is read into a sealed region and removed on CEF's
// TID_FILE_USER_BLOCKING thread, never on the UI thread, and Done runs on
// the UI thread. A browser that is gone, a refused print or a PDF over
// control::kMaxSharedBytes is -1.
class CefPdfPrinter final : public PdfPrinter {
 public:
  void Print(int chromium_id, const PrintToPdf& print, Done done) override;

 private:
  uint32_t serial_ = 0;  // names each print's file
};

// --- Prints the page starts ----------------------------------------------

inline constexpr uint16_t kOpPagePrints = 0x8066;
inline constexpr uint16_t kOpPagePrintEnd = 0x8067;
// The kOpPagePrints and kOpPagePrintEnd layouts this side writes.
inline constexpr int32_t kPagePrintsVersion = 1;
// The name a host whose fork has the print request hook lists in its HELLO.
inline constexpr char kPagePrintsHelloName[] = "cmux_host_page_prints";
// CMUX_SHIM_PAGE_PRINT (plans/cmux-next/chromium-host-ops.json, optional_events).
inline constexpr int kEventPagePrint = 61;
// Requests waiting for cmux at once: a page waits in at most one (its
// renderer is held in window.print()), so this is pages, not prints. One past
// it ends at once.
inline constexpr size_t kMaxPagePrintRequests = 64;

// The fork's hook (above).
using PrintRequestFn = void (*)(void* ctx, int browser_id, int64_t request);
using SetPrintRequestHandlerFn = int (*)(PrintRequestFn fn, void* ctx);
using EndPrintRequestFn = int (*)(int64_t request);

inline void WritePagePrints(bool enabled, control::TlvWriter* w) {
  w->I32(kPagePrintsVersion);
  w->I32(enabled ? 1 : 0);
}

// kOpPagePrints' enabled; nullopt for a malformed op (no version or one below
// 1, enabled not 0 or 1, version 1 with more fields).
inline std::optional<bool> DecodePagePrints(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t version = r.I32();
  const int32_t enabled = r.I32();
  if (!r.ok() || version < 1 || (enabled != 0 && enabled != 1)) return std::nullopt;
  if (version == kPagePrintsVersion && !r.AtEnd()) return std::nullopt;
  return enabled == 1;
}

inline void WritePagePrintEnd(int64_t request, control::TlvWriter* w) {
  w->I32(kPagePrintsVersion);
  w->I64(request);
}

// kOpPagePrintEnd's request; nullopt for a malformed op (as DecodePagePrints,
// or request 0, which the fork never makes).
inline std::optional<int64_t> DecodePagePrintEnd(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t version = r.I32();
  const int64_t request = r.I64();
  if (!r.ok() || version < 1 || request == 0) return std::nullopt;
  if (version == kPagePrintsVersion && !r.AtEnd()) return std::nullopt;
  return request;
}

// The page print requests the host handed to cmux and cmux has not ended, by
// the fork's request, with each one's page (its Chromium id). Main thread
// only, like host_dispatch.h.
class PagePrintRequests {
 public:
  // False for request 0, one already waiting, or one past
  // kMaxPagePrintRequests: the caller ends it at once.
  bool Add(int64_t request, int chromium_id) {
    if (request == 0 || pages_.size() >= kMaxPagePrintRequests || pages_.count(request) > 0) return false;
    pages_.emplace(request, chromium_id);
    return true;
  }
  // True when `request` was waiting: the caller ends it in the fork.
  bool End(int64_t request) { return pages_.erase(request) > 0; }
  // The page closed: the fork ended its request with it.
  void BrowserClosed(int chromium_id) {
    std::erase_if(pages_, [chromium_id](const auto& entry) { return entry.second == chromium_id; });
  }
  // Every waiting request, forgotten here: the caller ends each.
  std::vector<int64_t> TakeAll() {
    std::vector<int64_t> out;
    out.reserve(pages_.size());
    for (const auto& entry : pages_) out.push_back(entry.first);
    pages_.clear();
    return out;
  }
  size_t size() const { return pages_.size(); }

 private:
  std::unordered_map<int64_t, int> pages_;
};

}  // namespace cmux_host
