#include <cmux/client.hpp>
#include <cmux/raw/client.hpp>
#include <cmux/version.hpp>

#include <type_traits>
#include <utility>

static_assert(std::is_same_v<
              decltype(std::declval<cmux::Workspace&>().refresh()),
              cmux::Result<cmux::WorkspaceSnapshot>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Terminal&>().wait_exit()),
              cmux::Result<cmux::TerminalWaitExitResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().identify()),
              cmux::Result<cmux::raw::IdentifyResult>>);
static_assert(!std::is_copy_constructible_v<cmux::SessionEventStream>);
static_assert(std::is_nothrow_move_constructible_v<cmux::SessionEventStream>);

int main() {
    auto id = cmux::WorkspaceId::parse(
        "ws_0123456789abcdef0123456789abcdef");
    if (!id) {
        return 1;
    }
    const auto selector =
        cmux::Selector<cmux::WorkspaceId>::exact_name("current");
    auto command = cmux::RunCommand::exact({"cargo", "test"});
    cmux::raw::IdentifyRequest raw_request;
    return selector.wire() != "name:current" || !command ||
                   command.value().argv().size() != 2 ||
                   !(raw_request == cmux::raw::IdentifyRequest{}) ||
                   cmux::kSdkVersion != "1.0.0"
               ? 1
               : 0;
}
