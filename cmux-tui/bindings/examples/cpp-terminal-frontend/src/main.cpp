#include <charconv>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <string_view>

#include "cmux_example/frontend.hpp"

namespace {

volatile std::sig_atomic_t stop_requested = 0;

void handle_signal(int) {
    stop_requested = 1;
}

void print_usage(std::ostream& output, std::string_view program) {
    output
        << "Usage: " << program
        << " [--session NAME] [--socket PATH] [--surface ID]"
           " [--cols N] [--rows N] [--reconnects N]\n";
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

}  // namespace

int main(int argc, char** argv) {
    cmux_example::FrontendConfig config;

    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--help" || argument == "-h") {
            print_usage(std::cout, argv[0]);
            return EXIT_SUCCESS;
        }
        if (argument == "--session") {
            auto value = next_value(index, argc, argv, argument);
            if (!value) {
                return EXIT_FAILURE;
            }
            config.client_options.session = std::string(*value);
            continue;
        }
        if (argument == "--socket") {
            auto value = next_value(index, argc, argv, argument);
            if (!value) {
                return EXIT_FAILURE;
            }
            config.client_options.socket_path = std::string(*value);
            continue;
        }
        if (argument == "--surface") {
            auto value = next_value(index, argc, argv, argument);
            auto parsed = value ? parse_integer<std::uint64_t>(*value) : std::nullopt;
            if (!parsed) {
                std::cerr << "--surface must be an unsigned integer\n";
                return EXIT_FAILURE;
            }
            config.preferred_surface = cmux::Id{*parsed};
            continue;
        }
        if (argument == "--cols" || argument == "--rows") {
            auto value = next_value(index, argc, argv, argument);
            auto parsed = value ? parse_integer<std::uint32_t>(*value) : std::nullopt;
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
        if (argument == "--reconnects") {
            auto value = next_value(index, argc, argv, argument);
            auto parsed = value ? parse_integer<std::size_t>(*value) : std::nullopt;
            if (!parsed) {
                std::cerr << "--reconnects must be an unsigned integer\n";
                return EXIT_FAILURE;
            }
            config.max_reconnects = *parsed;
            continue;
        }

        std::cerr << "unknown option: " << argument << '\n';
        print_usage(std::cerr, argv[0]);
        return EXIT_FAILURE;
    }

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    cmux_example::TerminalFrontend frontend(std::move(config));
    auto result = frontend.run(
        [] { return stop_requested != 0; },
        [](const cmux_example::ScreenBuffer& screen) {
            std::cout << "\x1b[2J\x1b[H" << screen.plain_text()
                      << "\n\nsurface=" << screen.surface.value
                      << " grid=" << screen.size.cols << 'x' << screen.size.rows
                      << " scroll=" << screen.scroll_offset
                      << (screen.at_bottom ? " bottom" : "") << std::flush;
        });

    std::cout << "\x1b[0m\n";
    if (!result) {
        std::cerr << "cmux frontend failed [" << result.error().code_name()
                  << "]: " << result.error().message << '\n';
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
