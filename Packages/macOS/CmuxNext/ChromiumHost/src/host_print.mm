// The Chromium Host's printer (host_print.h, task p01-process-065):
// CefBrowserHost::PrintToPDF, then the file read into a sealed region off the
// UI thread. Chrome's headless printToPDF hands its document back as bytes in
// memory (components/printing/browser/print_to_pdf/pdf_print_job.cc); CEF's
// PrintToPDF takes only a path, so the host gives it one of its own and the
// region replaces the file before anything leaves the host.

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>

#include "include/cef_browser.h"
#include "include/cef_task.h"

#include "chromium_host_control.h"
#include "host_print.h"
#include "shim_internal.h"

namespace cmux_host {
namespace {

// Runs a print's Done on the UI thread; a task CEF drops unrun closes the
// region it carries.
class DoneTask : public CefTask {
 public:
  DoneTask(PdfPrinter::Done done, int fd, uint64_t size) : done_(std::move(done)), fd_(fd), size_(size) {}
  ~DoneTask() override {
    if (fd_ >= 0) close(fd_);
  }
  void Execute() override {
    const int fd = std::exchange(fd_, -1);
    done_(fd, size_);
  }

 private:
  PdfPrinter::Done done_;
  int fd_;
  uint64_t size_;
  IMPLEMENT_REFCOUNTING(DoneTask);
};

// A print's Done, run once on the UI thread: by Finish, or with -1 when the
// last holder lets it go unrun (CEF released the print's callback without
// calling it).
class OnceDone {
 public:
  explicit OnceDone(PdfPrinter::Done done) : done_(std::move(done)) {}
  OnceDone(const OnceDone&) = delete;
  OnceDone& operator=(const OnceDone&) = delete;
  ~OnceDone() { Finish(-1, 0); }

  // Hands `fd` (owned from here) to Done, on the UI thread.
  void Finish(int fd, uint64_t size) {
    PdfPrinter::Done done = std::exchange(done_, nullptr);
    if (!done) {
      if (fd >= 0) close(fd);
      return;
    }
    if (CefCurrentlyOn(TID_UI)) {
      done(fd, size);
      return;
    }
    // A refused post releases the task, which closes `fd`.
    CefPostTask(TID_UI, new DoneTask(std::move(done), fd, size));
  }

 private:
  PdfPrinter::Done done_;
};

// The printed file into a sealed region for `done`, then gone (with no
// `done`: only gone); blocking I/O, so on TID_FILE_USER_BLOCKING (the person
// waits for the panel).
class ReadPdfTask : public CefTask {
 public:
  ReadPdfTask(std::string path, std::unique_ptr<OnceDone> done) : path_(std::move(path)), done_(std::move(done)) {}
  void Execute() override {
    std::string pdf;
    const bool read = done_ && Read(&pdf);
    unlink(path_.c_str());
    if (!done_) return;
    const int fd = read ? control::CreateSharedRegion(pdf) : -1;
    done_->Finish(fd, fd >= 0 ? pdf.size() : 0);
  }

 private:
  bool Read(std::string* out) const {
    const int fd = open(path_.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    struct stat info;
    bool ok = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 &&
              static_cast<uint64_t>(info.st_size) <= control::kMaxSharedBytes;
    if (ok) {
      out->resize(static_cast<size_t>(info.st_size));
      size_t at = 0;
      while (ok && at < out->size()) {
        const ssize_t n = read(fd, out->data() + at, out->size() - at);
        if (n > 0) {
          at += static_cast<size_t>(n);
        } else if (n == 0 || errno != EINTR) {
          ok = false;
        }
      }
    }
    close(fd);
    return ok;
  }

  const std::string path_;
  std::unique_ptr<OnceDone> done_;
  IMPLEMENT_REFCOUNTING(ReadPdfTask);
};

// PrintToPDF's answer (UI thread).
class PdfPrinted : public CefPdfPrintCallback {
 public:
  PdfPrinted(std::string path, PdfPrinter::Done done)
      : path_(std::move(path)), done_(std::make_unique<OnceDone>(std::move(done))) {}
  void OnPdfPrintFinished(const CefString&, bool ok) override {
    if (!done_) return;
    // A failed print may have left a partial file: the read task removes it either way.
    if (!ok) {
      CefPostTask(TID_FILE_USER_BLOCKING, new ReadPdfTask(path_, nullptr));
      done_->Finish(-1, 0);
      done_.reset();
      return;
    }
    // A refused post (Chromium shutting down) drops the task, whose OnceDone answers -1.
    CefPostTask(TID_FILE_USER_BLOCKING, new ReadPdfTask(path_, std::move(done_)));
  }

 private:
  const std::string path_;
  std::unique_ptr<OnceDone> done_;
  IMPLEMENT_REFCOUNTING(PdfPrinted);
};

// The host's temporary directory (the per-user one launchd gives the app's
// children), ending in '/'; empty when there is none.
std::string TemporaryDirectory() {
  char buffer[1024];
  const size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, buffer, sizeof buffer);
  if (length == 0 || length > sizeof buffer) return std::string();
  std::string dir(buffer);
  if (dir.empty() || dir.back() != '/') dir.push_back('/');
  return dir;
}

}  // namespace

void CefPdfPrinter::Print(int chromium_id, const PrintToPdf& print, Done done) {
  CefRefPtr<CefBrowser> browser = cmux_shim::BrowserById(chromium_id);
  const std::string dir = TemporaryDirectory();
  if (!browser || dir.empty()) return done(-1, 0);
  char name[96];
  std::snprintf(name, sizeof name, "cmux-host-print-%d-%u.pdf", static_cast<int>(getpid()), ++serial_);
  const std::string path = dir + name;
  CefPdfPrintSettings settings;
  // Chromium's default paper (US Letter) when cmux sends none.
  settings.paper_width = print.paper_width;
  settings.paper_height = print.paper_height;
  browser->GetHost()->PrintToPDF(path, settings, new PdfPrinted(path, std::move(done)));
}

}  // namespace cmux_host
