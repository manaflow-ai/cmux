#pragma once

#include <cstdint>
#include <memory>

#include "cmux/raw/client_core.hpp"
#include "cmux/raw/generated/events.hpp"

namespace cmux::raw {

// A render stream and its size lease on one dedicated protocol connection.
//
// Surface size claims belong to the connection that created them. Keeping the
// event stream and sizing commands in this object prevents commands from being
// accidentally routed through a separate control Client.
class SurfaceAttachment {
public:
    SurfaceAttachment(const SurfaceAttachment&) = delete;
    SurfaceAttachment& operator=(const SurfaceAttachment&) = delete;
    SurfaceAttachment(SurfaceAttachment&& other) noexcept;
    SurfaceAttachment& operator=(SurfaceAttachment&& other) noexcept;
    ~SurfaceAttachment();

    [[nodiscard]] static Result<SurfaceAttachment> connect(
        const AttachSurfaceRequest& request,
        ClientOptions options = {},
        RequestOptions request_options = {});

    [[nodiscard]] Id surface() const noexcept;
    [[nodiscard]] std::uint64_t client_id() const noexcept;

    // Request and attachment-open deadlines do not end an acknowledged idle stream.
    [[nodiscard]] Result<Event> next();
    // Bounds one wait without closing the attachment when the wait times out.
    [[nodiscard]] Result<Event> next(Timeout timeout);

    [[nodiscard]] Result<ResizeSurfaceResult> resize(
        std::uint16_t cols,
        std::uint16_t rows,
        RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> set_sizing(
        bool enabled,
        bool exclusive = false,
        RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> release_size(RequestOptions options = {});

    void close() noexcept;
    [[nodiscard]] bool closed() const noexcept;

private:
    struct Impl;
    explicit SurfaceAttachment(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

using RenderAttachment = SurfaceAttachment;

[[nodiscard]] Result<RenderAttachment> open_render_attachment(
    const AttachSurfaceRequest& request,
    ClientOptions options = {},
    RequestOptions request_options = {});

}  // namespace cmux::raw
