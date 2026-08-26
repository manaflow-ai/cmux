"""Dependency-free Python SDK for the cmux resource API."""

from . import aio
from .client_defaults import default_socket_path, env_socket_path
from .errors import (
    CancelledError,
    CmuxConnectionError,
    CmuxError,
    ConfirmationRequiredDetails,
    ConfirmationRequiredError,
    MutationIndeterminateDetails,
    MutationIndeterminateError,
    MutationTransportError,
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
    Screen,
    Session,
    SessionCreation,
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
            "CancelledError",
            "CmuxConnectionError",
            "CmuxError",
            "ConfirmationRequiredDetails",
            "ConfirmationRequiredError",
            "ConnectedClient",
            "CreatedPath",
            "FrontendProjection",
            "Machine",
            "MutationIndeterminateDetails",
            "MutationIndeterminateError",
            "MutationTransportError",
            "Notification",
            "PairingRequest",
            "Pane",
            "ProtocolError",
            "ResourceError",
            "Screen",
            "Session",
            "SessionCreation",
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
