#include <cmux/client.hpp>
#include <cmux/version.hpp>

#include <chrono>
#include <type_traits>
#include <utility>

static_assert(std::is_same_v<
              decltype(std::declval<cmux::Client&>().identify()),
              cmux::Result<cmux::IdentifyResult>>);
static_assert(!std::is_copy_constructible_v<cmux::RenderAttachment>);
static_assert(std::is_nothrow_move_constructible_v<cmux::RenderAttachment>);
static_assert(std::is_same_v<
              decltype(cmux::open_render_attachment(
                  std::declval<const cmux::AttachSurfaceRequest&>(),
                  std::declval<cmux::ClientOptions>(),
                  std::declval<cmux::RequestOptions>())),
              cmux::Result<cmux::RenderAttachment>>);

cmux::Result<cmux::RenderAttachment> open_attachment(
    const cmux::AttachSurfaceRequest& request,
    cmux::ClientOptions options) {
    return cmux::open_render_attachment(request, std::move(options));
}

int use_attachment(cmux::RenderAttachment& attachment) {
    auto resized = attachment.resize(120, 40);
    auto sizing = attachment.set_sizing(true, true);
    auto event = attachment.next(std::chrono::milliseconds(1));
    auto released = attachment.release_size();
    const auto surface = attachment.surface();
    const auto client = attachment.client_id();
    attachment.close();
    return resized.has_value() || sizing.has_value() || event.has_value() ||
                   released.has_value() || surface.value != 0 || client != 0 ||
                   !attachment.closed()
               ? 0
               : 1;
}

int main() {
    cmux::ClientOptions options;
    options.session = "package-consumer";
    const bool standard_authorities =
        options.authorities.control && options.authorities.frontend &&
        options.authorities.local_admin &&
        !options.authorities.provider_authority;
    cmux::IdentifyRequest request;
    return options.session.empty() || !standard_authorities ||
                   !(request == cmux::IdentifyRequest{}) ||
                   cmux::kSdkVersion != "0.4.0"
               ? 1
               : 0;
}
