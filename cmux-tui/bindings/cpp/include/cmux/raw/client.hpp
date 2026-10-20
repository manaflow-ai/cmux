#pragma once

// Low-level protocol-v12 compatibility layer. Prefer <cmux/client.hpp>.
#include "cmux/raw/attachment.hpp"
#include "cmux/raw/generated/commands.hpp"

namespace cmux::raw {

using ::cmux::Error;
using ::cmux::ErrorCode;
using ::cmux::Json;
using ::cmux::JsonLimits;
using ::cmux::Timeout;
using ::cmux::Transport;
using ::cmux::TransportFactory;
using ::cmux::TransportLimits;
using ::cmux::UnixTransport;
using ::cmux::default_socket_path;
using ::cmux::make_error;
using ::cmux::socket_path_from_environment;
using ::cmux::unix_transport_factory;

template <typename T>
using result = ::cmux::Result<T>;
template <typename T>
using Result = ::cmux::Result<T>;

}  // namespace cmux::raw
