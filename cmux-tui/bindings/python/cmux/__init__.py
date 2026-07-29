"""Dependency-free Python SDK for the cmux resource API."""

from . import aio
from .client_defaults import default_socket_path, env_socket_path
from .errors import (
    CmuxConnectionError,
    CmuxError,
    MutationIndeterminateDetails,
    MutationIndeterminateError,
    ProtocolError,
    ResourceError,
    StreamError,
    TimeoutError,
)
from .ids import *
from .ids import __all__ as _id_all
from .models import *
from .models import __all__ as _model_all
from .options import *
from .options import __all__ as _option_all
from .resources import (
    Agent,
    Browser,
    Client,
    ConnectedClient,
    CreatedPath,
    FrontendProjection,
    Machine,
    Notification,
    PairingRequest,
    Pane,
    ProviderAction,
    ProviderNotice,
    ProviderScope,
    Screen,
    Session,
    SidebarView,
    Tab,
    Terminal,
    Workspace,
)

__all__ = list(
    dict.fromkeys(
        (
            "Agent",
            "Browser",
            "Client",
            "CmuxConnectionError",
            "CmuxError",
            "ConnectedClient",
            "CreatedPath",
            "FrontendProjection",
            "Machine",
            "MutationIndeterminateDetails",
            "MutationIndeterminateError",
            "Notification",
            "PairingRequest",
            "Pane",
            "ProtocolError",
            "ProviderAction",
            "ProviderNotice",
            "ProviderScope",
            "ResourceError",
            "Screen",
            "Session",
            "SidebarView",
            "StreamError",
            "Tab",
            "Terminal",
            "TimeoutError",
            "Workspace",
            "aio",
            "default_socket_path",
            "env_socket_path",
            *_id_all,
            *_model_all,
            *_option_all,
        )
    )
)
