#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "cmux/client.hpp"

namespace cmux_example {

struct ScreenBuffer {
    cmux::Id surface{};
    cmux::Size size{};
    cmux::RenderCursor cursor{};
    cmux::ColorHex default_foreground{};
    cmux::ColorHex default_background{};
    std::uint32_t scrollback_rows = 0;
    std::uint64_t scroll_offset = 0;
    bool at_bottom = true;
    bool has_snapshot = false;
    std::vector<cmux::RenderRow> rows;

    void clear() noexcept;
    [[nodiscard]] cmux::Result<void> apply(const cmux::RenderStateEvent& event);
    [[nodiscard]] cmux::Result<void> apply(const cmux::RenderDeltaEvent& event);
    [[nodiscard]] cmux::Result<void> apply(const cmux::ScrollChangedEvent& event);
    [[nodiscard]] std::string plain_text() const;
};

struct FrontendConfig {
    cmux::ClientOptions client_options{};
    std::optional<cmux::Id> preferred_surface;
    std::uint16_t columns = 100;
    std::uint16_t rows = 30;
    std::size_t max_reconnects = 3;
    std::chrono::milliseconds reconnect_delay{250};
    std::chrono::milliseconds stream_poll_timeout{100};
};

struct FrontendStats {
    std::size_t connections = 0;
    std::size_t reconnects = 0;
    std::size_t snapshots = 0;
    std::size_t deltas = 0;
    std::size_t scroll_updates = 0;
    std::size_t overflows = 0;
    std::size_t detaches = 0;
    std::size_t transport_failures = 0;
    std::size_t unknown_events = 0;
};

class TerminalFrontend {
public:
    using StopRequested = std::function<bool()>;
    using FrameCallback = std::function<void(const ScreenBuffer&)>;

    explicit TerminalFrontend(FrontendConfig config);

    [[nodiscard]] cmux::Result<void> run(
        StopRequested stop_requested,
        FrameCallback on_frame = {});

    [[nodiscard]] const ScreenBuffer& screen() const noexcept { return screen_; }
    [[nodiscard]] const FrontendStats& stats() const noexcept { return stats_; }
    [[nodiscard]] std::optional<cmux::Id> selected_surface() const noexcept {
        return selected_surface_;
    }

private:
    FrontendConfig config_;
    ScreenBuffer screen_;
    FrontendStats stats_;
    std::optional<cmux::Id> selected_surface_;
};

}  // namespace cmux_example
