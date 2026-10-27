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
// Plain C++, no CEF: the tests build it on Linux
// (scripts/cmux-next/tests/chromium-host-dispatch.test.sh). The printer that
// calls CEF is host_print.mm.
#pragma once

#include <cstdint>
#include <functional>
#include <optional>
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

}  // namespace cmux_host
