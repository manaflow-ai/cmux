#include <algorithm>
#include <charconv>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <variant>

#include "cmux_example/frontend.hpp"

namespace {

volatile std::sig_atomic_t stop_requested = 0;

void handle_signal(int) {
    stop_requested = 1;
}

void print_usage(std::ostream& output, std::string_view program) {
    output
        << "Usage: " << program
        << " [--session NAME] [--socket PATH] [--terminal TERM_ID]"
           " [--command SHELL] [--workspace WORKSPACE_ID] [--cwd PATH]"
           " [--correlation-key KEY] [--idempotency-key KEY]"
           " [--cols N] [--rows N] [--poll-ms N]\n";
}

template <typename T>
std::optional<T> parse_integer(std::string_view text) {
    T value{};
    const char* begin = text.data();
    const char* end = text.data() + text.size();
    const auto parsed = std::from_chars(begin, end, value);
    if (parsed.ec != std::errc{} || parsed.ptr != end) {
        return std::nullopt;
    }
    return value;
}

std::optional<std::string_view> next_value(
    int& index,
    int argc,
    char** argv,
    std::string_view option) {
    if (index + 1 >= argc) {
        std::cerr << option << " requires a value\n";
        return std::nullopt;
    }
    ++index;
    return std::string_view(argv[index]);
}

std::string generated_key() {
    const auto tick = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    return "cpp-frontend-" + std::to_string(tick);
}

std::string describe_exit(const cmux::TerminalWaitExitResult& waited) {
    if (const auto* pending =
            std::get_if<cmux::TerminalWaitExitPending>(&waited)) {
        return "pending (" + pending->lifecycle + ")";
    }
    const auto& exited = std::get<cmux::TerminalWaitExitExited>(waited);
    if (const auto* code =
            std::get_if<cmux::TerminalExitCode>(&exited.outcome)) {
        return "exit " + std::to_string(code->code);
    }
    if (const auto* signal =
            std::get_if<cmux::TerminalExitSignal>(&exited.outcome)) {
        return "signal " + std::to_string(signal->signal);
    }
    return "unknown: " +
           std::get<cmux::TerminalExitUnknown>(exited.outcome).reason;
}

int process_exit_code(const cmux::TerminalWaitExitResult& waited) {
    const auto* exited =
        std::get_if<cmux::TerminalWaitExitExited>(&waited);
    if (!exited) {
        return EXIT_SUCCESS;
    }
    if (const auto* code =
            std::get_if<cmux::TerminalExitCode>(&exited->outcome)) {
        return std::clamp<std::int32_t>(code->code, 0, 255);
    }
    if (const auto* signal =
            std::get_if<cmux::TerminalExitSignal>(&exited->outcome)) {
        return std::min(255, 128 + signal->signal);
    }
    return EXIT_FAILURE;
}

}  // namespace

int main(int argc, char** argv) {
    cmux_example::FrontendConfig config;
    std::optional<std::string> command;
    std::optional<std::string> cwd;
    std::optional<cmux::WorkspaceId> workspace;
    std::optional<std::string> correlation_key;
    std::optional<std::string> idempotency_key;

    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--help" || argument == "-h") {
            print_usage(std::cout, argv[0]);
            return EXIT_SUCCESS;
        }
        if (argument == "--session" || argument == "--socket" ||
            argument == "--command" || argument == "--cwd" ||
            argument == "--correlation-key" ||
            argument == "--idempotency-key") {
            auto value = next_value(index, argc, argv, argument);
            if (!value) {
                return EXIT_FAILURE;
            }
            if (argument == "--session") {
                config.client_options.session = std::string(*value);
            } else if (argument == "--socket") {
                config.client_options.socket_path = std::string(*value);
            } else if (argument == "--command") {
                command = std::string(*value);
            } else if (argument == "--cwd") {
                cwd = std::string(*value);
            } else if (argument == "--correlation-key") {
                correlation_key = std::string(*value);
            } else {
                idempotency_key = std::string(*value);
            }
            continue;
        }
        if (argument == "--terminal") {
            auto value = next_value(index, argc, argv, argument);
            auto parsed = value
                ? cmux::TerminalId::parse(*value)
                : cmux::Result<cmux::TerminalId>(
                      cmux::make_error(
                          cmux::ErrorCode::invalid_argument,
                          "missing terminal ID"));
            if (!parsed) {
                std::cerr << "--terminal: " << parsed.error().message << '\n';
                return EXIT_FAILURE;
            }
            config.preferred_terminal = std::move(parsed).value();
            continue;
        }
        if (argument == "--workspace") {
            auto value = next_value(index, argc, argv, argument);
            auto parsed = value
                ? cmux::WorkspaceId::parse(*value)
                : cmux::Result<cmux::WorkspaceId>(
                      cmux::make_error(
                          cmux::ErrorCode::invalid_argument,
                          "missing workspace ID"));
            if (!parsed) {
                std::cerr << "--workspace: " << parsed.error().message << '\n';
                return EXIT_FAILURE;
            }
            workspace = std::move(parsed).value();
            continue;
        }
        if (argument == "--cols" || argument == "--rows") {
            auto value = next_value(index, argc, argv, argument);
            auto parsed = value
                ? parse_integer<std::uint32_t>(*value)
                : std::nullopt;
            if (!parsed || *parsed == 0 ||
                *parsed > std::numeric_limits<std::uint16_t>::max()) {
                std::cerr << argument << " must be between 1 and 65535\n";
                return EXIT_FAILURE;
            }
            if (argument == "--cols") {
                config.columns = static_cast<std::uint16_t>(*parsed);
            } else {
                config.rows = static_cast<std::uint16_t>(*parsed);
            }
            continue;
        }
        if (argument == "--poll-ms") {
            auto value = next_value(index, argc, argv, argument);
            auto parsed = value
                ? parse_integer<std::uint64_t>(*value)
                : std::nullopt;
            if (!parsed || *parsed == 0 ||
                *parsed >
                    static_cast<std::uint64_t>(
                        std::numeric_limits<std::int64_t>::max())) {
                std::cerr << "--poll-ms must be a positive integer\n";
                return EXIT_FAILURE;
            }
            config.stream_poll_timeout =
                std::chrono::milliseconds(*parsed);
            continue;
        }

        std::cerr << "unknown option: " << argument << '\n';
        print_usage(std::cerr, argv[0]);
        return EXIT_FAILURE;
    }

    if (config.preferred_terminal && command) {
        std::cerr << "--terminal and --command are mutually exclusive\n";
        return EXIT_FAILURE;
    }
    if (!command &&
        (workspace || cwd || correlation_key || idempotency_key)) {
        std::cerr
            << "--workspace, --cwd, and mutation keys require --command\n";
        return EXIT_FAILURE;
    }
    if (command) {
        auto run_command = cmux::RunCommand::shell(*command);
        if (!run_command) {
            std::cerr << run_command.error().message << '\n';
            return EXIT_FAILURE;
        }
        const std::string base = generated_key();
        cmux_example::LaunchRequest launch(
            std::move(run_command).value(),
            correlation_key.value_or(base),
            idempotency_key.value_or(base + "-attempt-1"));
        launch.workspace = std::move(workspace);
        launch.cwd = std::move(cwd);
        launch.name = "cpp-frontend";
        config.launch = std::move(launch);
    }

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    cmux_example::TerminalFrontend frontend(std::move(config));
    auto result = frontend.run(
        [] { return stop_requested != 0; },
        [](const cmux_example::ScreenBuffer& screen) {
            std::cout << "\x1b[2J\x1b[H" << screen.plain_text()
                      << std::flush;
        });
    if (!result) {
        std::cerr << "\nfrontend failed [" << result.error().code_name()
                  << "]: " << result.error().message << '\n';
        return EXIT_FAILURE;
    }

    std::cout << '\n';
    if (frontend.selected_terminal()) {
        std::cout << "terminal="
                  << frontend.selected_terminal()->value() << '\n';
    }
    if (frontend.initial_screen()) {
        std::cout << "--- initial screen ---\n"
                  << frontend.initial_screen()->text << '\n';
    }
    if (frontend.initial_history()) {
        std::cout << "--- history ---\n"
                  << cmux_example::plain_text(
                         *frontend.initial_history())
                  << '\n';
    }
    if (frontend.exit_wait()) {
        std::cout << "process="
                  << describe_exit(*frontend.exit_wait()) << '\n';
        return process_exit_code(*frontend.exit_wait());
    }
    return EXIT_SUCCESS;
}
