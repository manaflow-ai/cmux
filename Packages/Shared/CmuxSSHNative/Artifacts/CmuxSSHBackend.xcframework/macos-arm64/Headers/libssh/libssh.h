/*
 * This file is part of the SSH Library
 *
 * Copyright (c) 2003-2026 by Aris Adamantiadis and the libssh team
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef _LIBSSH_H
#define _LIBSSH_H

#include <libssh/libssh_version.h>

#if defined _WIN32 || defined __CYGWIN__
  #ifdef LIBSSH_STATIC
    #define LIBSSH_API
  #else
    #ifdef LIBSSH_EXPORTS
      #ifdef __GNUC__
        #define LIBSSH_API __attribute__((dllexport))
      #else
        #define LIBSSH_API __declspec(dllexport)
      #endif
    #else
      #ifdef __GNUC__
        #define LIBSSH_API __attribute__((dllimport))
      #else
        #define LIBSSH_API __declspec(dllimport)
      #endif
    #endif
  #endif
#else
  #if __GNUC__ >= 4 && !defined(__OS2__)
    #define LIBSSH_API __attribute__((visibility("default")))
  #else
    #define LIBSSH_API
  #endif
#endif

#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef _MSC_VER
  typedef int mode_t;
#else /* _MSC_VER */
  #include <unistd.h>
  #include <sys/types.h>
#endif /* _MSC_VER */

#ifdef _WIN32
  #include <winsock2.h>
#else /* _WIN32 */
 #include <sys/select.h> /* for fd_set * */
 #include <netdb.h>
#endif /* _WIN32 */

#define SSH_STRINGIFY(s) SSH_TOSTRING(s)
#define SSH_TOSTRING(s) #s

/* GCC have printf type attribute check.  */
#ifdef __GNUC__
#define PRINTF_ATTRIBUTE(a,b) __attribute__ ((__format__ (__printf__, a, b)))
#else
#define PRINTF_ATTRIBUTE(a,b)
#endif /* __GNUC__ */

#if !defined(SSH_SUPPRESS_DEPRECATED) && defined(__GNUC__)
#define SSH_DEPRECATED __attribute__ ((deprecated))
#else
#define SSH_DEPRECATED
#endif

#ifdef __cplusplus
extern "C" {
#endif

struct ssh_counter_struct {
    uint64_t in_bytes;
    uint64_t out_bytes;
    uint64_t in_packets;
    uint64_t out_packets;
};
typedef struct ssh_counter_struct *ssh_counter;

typedef struct ssh_agent_struct* ssh_agent;
typedef struct ssh_buffer_struct* ssh_buffer;
typedef struct ssh_channel_struct* ssh_channel;
typedef struct ssh_message_struct* ssh_message;
typedef struct ssh_pcap_file_struct* ssh_pcap_file;
typedef struct ssh_key_struct* ssh_key;
typedef struct ssh_scp_struct* ssh_scp;
typedef struct ssh_session_struct* ssh_session;
typedef struct ssh_string_struct* ssh_string;
typedef struct ssh_event_struct* ssh_event;
typedef struct ssh_connector_struct * ssh_connector;
typedef struct ssh_pki_ctx_struct *ssh_pki_ctx;
typedef void* ssh_gssapi_creds;

/* Socket type */
#ifdef _WIN32
#ifndef socket_t
typedef SOCKET socket_t;
#endif /* socket_t */
#else /* _WIN32 */
#ifndef socket_t
typedef int socket_t;
#endif
#endif /* _WIN32 */

#define SSH_INVALID_SOCKET ((socket_t) -1)

/* the offsets of methods */
enum ssh_kex_types_e {
	SSH_KEX=0,
	SSH_HOSTKEYS,
	SSH_CRYPT_C_S,
	SSH_CRYPT_S_C,
	SSH_MAC_C_S,
	SSH_MAC_S_C,
	SSH_COMP_C_S,
	SSH_COMP_S_C,
	SSH_LANG_C_S,
	SSH_LANG_S_C
};

#define SSH_CRYPT 2
#define SSH_MAC 3
#define SSH_COMP 4
#define SSH_LANG 5

enum ssh_auth_e {
	SSH_AUTH_SUCCESS=0,
	SSH_AUTH_DENIED,
	SSH_AUTH_PARTIAL,
	SSH_AUTH_INFO,
	SSH_AUTH_AGAIN,
	SSH_AUTH_ERROR=-1
};

/* auth flags */
#define SSH_AUTH_METHOD_UNKNOWN      0x0000u
#define SSH_AUTH_METHOD_NONE         0x0001u
#define SSH_AUTH_METHOD_PASSWORD     0x0002u
#define SSH_AUTH_METHOD_PUBLICKEY    0x0004u
#define SSH_AUTH_METHOD_HOSTBASED    0x0008u
#define SSH_AUTH_METHOD_INTERACTIVE  0x0010u
#define SSH_AUTH_METHOD_GSSAPI_MIC   0x0020u
#define SSH_AUTH_METHOD_GSSAPI_KEYEX 0x0040u

/* messages */
enum ssh_requests_e {
	SSH_REQUEST_AUTH=1,
	SSH_REQUEST_CHANNEL_OPEN,
	SSH_REQUEST_CHANNEL,
	SSH_REQUEST_SERVICE,
	SSH_REQUEST_GLOBAL
};

enum ssh_channel_type_e {
	SSH_CHANNEL_UNKNOWN=0,
	SSH_CHANNEL_SESSION,
	SSH_CHANNEL_DIRECT_TCPIP,
	SSH_CHANNEL_FORWARDED_TCPIP,
	SSH_CHANNEL_X11,
	SSH_CHANNEL_AUTH_AGENT
};

enum ssh_channel_requests_e {
	SSH_CHANNEL_REQUEST_UNKNOWN=0,
	SSH_CHANNEL_REQUEST_PTY,
	SSH_CHANNEL_REQUEST_EXEC,
	SSH_CHANNEL_REQUEST_SHELL,
	SSH_CHANNEL_REQUEST_ENV,
	SSH_CHANNEL_REQUEST_SUBSYSTEM,
	SSH_CHANNEL_REQUEST_WINDOW_CHANGE,
	SSH_CHANNEL_REQUEST_X11
};

enum ssh_global_requests_e {
	SSH_GLOBAL_REQUEST_UNKNOWN=0,
	SSH_GLOBAL_REQUEST_TCPIP_FORWARD,
	SSH_GLOBAL_REQUEST_CANCEL_TCPIP_FORWARD,
	SSH_GLOBAL_REQUEST_KEEPALIVE,
	SSH_GLOBAL_REQUEST_NO_MORE_SESSIONS
};

enum ssh_publickey_state_e {
	SSH_PUBLICKEY_STATE_ERROR=-1,
	SSH_PUBLICKEY_STATE_NONE=0,
	SSH_PUBLICKEY_STATE_VALID=1,
	SSH_PUBLICKEY_STATE_WRONG=2
};

/* Status flags */
/** Socket is closed */
#define SSH_CLOSED 0x01
/** Reading to socket won't block */
#define SSH_READ_PENDING 0x02
/** Session was closed due to an error */
#define SSH_CLOSED_ERROR 0x04
/** Output buffer not empty */
#define SSH_WRITE_PENDING 0x08

enum ssh_server_known_e {
	SSH_SERVER_ERROR=-1,
	SSH_SERVER_NOT_KNOWN=0,
	SSH_SERVER_KNOWN_OK,
	SSH_SERVER_KNOWN_CHANGED,
	SSH_SERVER_FOUND_OTHER,
	SSH_SERVER_FILE_NOT_FOUND
};

enum ssh_known_hosts_e {
    /**
     * There had been an error checking the host.
     */
    SSH_KNOWN_HOSTS_ERROR = -2,

    /**
     * The known host file does not exist. The host is thus unknown. File will
     * be created if host key is accepted.
     */
    SSH_KNOWN_HOSTS_NOT_FOUND = -1,

    /**
     * The server is unknown. User should confirm the public key hash is
     * correct.
     */
    SSH_KNOWN_HOSTS_UNKNOWN = 0,

    /**
     * The server is known and has not changed.
     */
    SSH_KNOWN_HOSTS_OK,

    /**
     * The server key has changed. Either you are under attack or the
     * administrator changed the key. You HAVE to warn the user about a
     * possible attack.
     */
    SSH_KNOWN_HOSTS_CHANGED,

    /**
     * The server gave use a key of a type while we had an other type recorded.
     * It is a possible attack.
     */
    SSH_KNOWN_HOSTS_OTHER,
};

#ifndef MD5_DIGEST_LEN
    #define MD5_DIGEST_LEN 16
#endif
/* errors */

enum ssh_error_types_e {
	SSH_NO_ERROR=0,
	SSH_REQUEST_DENIED,
	SSH_FATAL,
	SSH_EINTR
};

/* some types for keys */
enum ssh_keytypes_e{
  SSH_KEYTYPE_UNKNOWN=0,
  SSH_KEYTYPE_DSS=1, /* deprecated */
  SSH_KEYTYPE_RSA,
  SSH_KEYTYPE_RSA1,
  SSH_KEYTYPE_ECDSA, /* deprecated */
  SSH_KEYTYPE_ED25519,
  SSH_KEYTYPE_DSS_CERT01, /* deprecated */
  SSH_KEYTYPE_RSA_CERT01,
  SSH_KEYTYPE_ECDSA_P256,
  SSH_KEYTYPE_ECDSA_P384,
  SSH_KEYTYPE_ECDSA_P521,
  SSH_KEYTYPE_ECDSA_P256_CERT01,
  SSH_KEYTYPE_ECDSA_P384_CERT01,
  SSH_KEYTYPE_ECDSA_P521_CERT01,
  SSH_KEYTYPE_ED25519_CERT01,
  SSH_KEYTYPE_SK_ECDSA,
  SSH_KEYTYPE_SK_ECDSA_CERT01,
  SSH_KEYTYPE_SK_ED25519,
  SSH_KEYTYPE_SK_ED25519_CERT01,
};

enum ssh_keycmp_e {
  SSH_KEY_CMP_PUBLIC = 0,
  SSH_KEY_CMP_PRIVATE = 1,
  SSH_KEY_CMP_CERTIFICATE = 2,
};

#define SSH_ADDRSTRLEN 46

struct ssh_knownhosts_entry {
    char *hostname;
    char *unparsed;
    ssh_key publickey;
    char *comment;
};


/* Error return codes */
#define SSH_OK 0     /* No error */
#define SSH_ERROR -1 /* Error of some kind */
#define SSH_AGAIN -2 /* The nonblocking call must be repeated */
#define SSH_EOF -127 /* We have already a eof */

/**
 * @addtogroup libssh_log
 *
 * @{
 */

enum {
	/** No logging at all
	 */
	SSH_LOG_NOLOG=0,
	/** Only unrecoverable errors
	 */
	SSH_LOG_WARNING,
	/** Information for the users
	 */
	SSH_LOG_PROTOCOL,
	/** Debug information, to see what is going on
	 */
	SSH_LOG_PACKET,
	/** Trace information and recoverable error messages
	 */
	SSH_LOG_FUNCTIONS
};
/** @} */
#define SSH_LOG_RARE SSH_LOG_WARNING

/**
 * @name Logging levels
 *
 * @brief Debug levels for logging.
 * @{
 */

/** No logging at all */
#define SSH_LOG_NONE 0
/** Show only fatal warnings */
#define SSH_LOG_WARN 1
/** Get some information what's going on */
#define SSH_LOG_INFO 2
/** Get detailed debugging information **/
#define SSH_LOG_DEBUG 3
/** Get trace output, packet information, ... */
#define SSH_LOG_TRACE 4

/** @} */

enum ssh_control_master_options_e {
  SSH_CONTROL_MASTER_NO,
  SSH_CONTROL_MASTER_AUTO,
  SSH_CONTROL_MASTER_YES,
  SSH_CONTROL_MASTER_ASK,
  SSH_CONTROL_MASTER_AUTOASK
};

enum ssh_address_family_options_e {
    SSH_ADDRESS_FAMILY_ANY,
    SSH_ADDRESS_FAMILY_INET,
    SSH_ADDRESS_FAMILY_INET6
};

enum ssh_options_e {
    SSH_OPTIONS_HOST,
    SSH_OPTIONS_PORT,
    SSH_OPTIONS_PORT_STR,
    SSH_OPTIONS_FD,
    SSH_OPTIONS_USER,
    SSH_OPTIONS_SSH_DIR,
    SSH_OPTIONS_IDENTITY,
    SSH_OPTIONS_ADD_IDENTITY,
    SSH_OPTIONS_KNOWNHOSTS,
    SSH_OPTIONS_TIMEOUT,
    SSH_OPTIONS_TIMEOUT_USEC,
    SSH_OPTIONS_SSH1,
    SSH_OPTIONS_SSH2,
    SSH_OPTIONS_LOG_VERBOSITY,
    SSH_OPTIONS_LOG_VERBOSITY_STR,
    SSH_OPTIONS_CIPHERS_C_S,
    SSH_OPTIONS_CIPHERS_S_C,
    SSH_OPTIONS_COMPRESSION_C_S,
    SSH_OPTIONS_COMPRESSION_S_C,
    SSH_OPTIONS_PROXYCOMMAND,
    SSH_OPTIONS_BINDADDR,
    SSH_OPTIONS_STRICTHOSTKEYCHECK,
    SSH_OPTIONS_COMPRESSION,
    SSH_OPTIONS_COMPRESSION_LEVEL,
    SSH_OPTIONS_KEY_EXCHANGE,
    SSH_OPTIONS_HOSTKEYS,
    SSH_OPTIONS_GSSAPI_SERVER_IDENTITY,
    SSH_OPTIONS_GSSAPI_CLIENT_IDENTITY,
    SSH_OPTIONS_GSSAPI_DELEGATE_CREDENTIALS,
    SSH_OPTIONS_HMAC_C_S,
    SSH_OPTIONS_HMAC_S_C,
    SSH_OPTIONS_PASSWORD_AUTH,
    SSH_OPTIONS_PUBKEY_AUTH,
    SSH_OPTIONS_KBDINT_AUTH,
    SSH_OPTIONS_GSSAPI_AUTH,
    SSH_OPTIONS_GLOBAL_KNOWNHOSTS,
    SSH_OPTIONS_NODELAY,
    SSH_OPTIONS_PUBLICKEY_ACCEPTED_TYPES,
    SSH_OPTIONS_PROCESS_CONFIG,
    SSH_OPTIONS_REKEY_DATA,
    SSH_OPTIONS_REKEY_TIME,
    SSH_OPTIONS_RSA_MIN_SIZE,
    SSH_OPTIONS_IDENTITY_AGENT,
    SSH_OPTIONS_IDENTITIES_ONLY,
    SSH_OPTIONS_CONTROL_MASTER,
    SSH_OPTIONS_CONTROL_PATH,
    SSH_OPTIONS_CERTIFICATE,
    SSH_OPTIONS_PROXYJUMP,
    SSH_OPTIONS_PROXYJUMP_CB_LIST_APPEND,
    SSH_OPTIONS_PKI_CONTEXT,
    SSH_OPTIONS_ADDRESS_FAMILY,
    SSH_OPTIONS_GSSAPI_KEY_EXCHANGE,
    SSH_OPTIONS_GSSAPI_KEY_EXCHANGE_ALGS,
    SSH_OPTIONS_NEXT_IDENTITY,
};

enum {
  /** Code is going to write/create remote files */
  SSH_SCP_WRITE,
  /** Code is going to read remote files */
  SSH_SCP_READ,
  SSH_SCP_RECURSIVE=0x10
};

enum ssh_scp_request_types {
  /** A new directory is going to be pulled */
  SSH_SCP_REQUEST_NEWDIR=1,
  /** A new file is going to be pulled */
  SSH_SCP_REQUEST_NEWFILE,
  /** End of requests */
  SSH_SCP_REQUEST_EOF,
  /** End of directory */
  SSH_SCP_REQUEST_ENDDIR,
  /** Warning received */
  SSH_SCP_REQUEST_WARNING
};

enum ssh_connector_flags_e {
    /** Only the standard stream of the channel */
    SSH_CONNECTOR_STDOUT = 1,
    SSH_CONNECTOR_STDINOUT = 1,
    /** Only the exception stream of the channel */
    SSH_CONNECTOR_STDERR = 2,
    /** Merge both standard and exception streams */
    SSH_CONNECTOR_BOTH = 3
};

LIBSSH_API int ssh_blocking_flush(ssh_session session, int timeout);
LIBSSH_API ssh_channel ssh_channel_accept_x11(ssh_channel channel, int timeout_ms);
LIBSSH_API int ssh_channel_change_pty_size(ssh_channel channel,int cols,int rows);
LIBSSH_API int ssh_channel_close(ssh_channel channel);
#define SSH_CHANNEL_FREE(x)      \
    do {                         \
        if ((x) != NULL) {       \
            ssh_channel_free(x); \
            (x) = NULL;          \
        }                        \
    } while (0)
LIBSSH_API void ssh_channel_free(ssh_channel channel);
LIBSSH_API int ssh_channel_get_exit_state(ssh_channel channel,
                                          uint32_t *pexit_code,
                                          char **pexit_signal,
                                          int *pcore_dumped);
SSH_DEPRECATED LIBSSH_API int ssh_channel_get_exit_status(ssh_channel channel);
LIBSSH_API ssh_session ssh_channel_get_session(ssh_channel channel);
LIBSSH_API int ssh_channel_is_closed(ssh_channel channel);
LIBSSH_API int ssh_channel_is_eof(ssh_channel channel);
LIBSSH_API int ssh_channel_is_open(ssh_channel channel);
LIBSSH_API ssh_channel ssh_channel_new(ssh_session session);
LIBSSH_API int ssh_channel_open_auth_agent(ssh_channel channel);
LIBSSH_API int ssh_channel_open_forward(ssh_channel channel, const char *remotehost,
    int remoteport, const char *sourcehost, int localport);
LIBSSH_API int ssh_channel_open_forward_unix(ssh_channel channel, const char *remotepath,
    const char *sourcehost, int localport);
LIBSSH_API int ssh_channel_open_session(ssh_channel channel);
LIBSSH_API int ssh_channel_open_x11(ssh_channel channel, const char *orig_addr, int orig_port);
LIBSSH_API int ssh_channel_poll(ssh_channel channel, int is_stderr);
LIBSSH_API int ssh_channel_poll_timeout(ssh_channel channel, int timeout, int is_stderr);
LIBSSH_API int ssh_channel_read(ssh_channel channel, void *dest, uint32_t count, int is_stderr);
LIBSSH_API int ssh_channel_read_timeout(ssh_channel channel, void *dest, uint32_t count, int is_stderr, int timeout_ms);
LIBSSH_API int ssh_channel_read_nonblocking(ssh_channel channel, void *dest, uint32_t count,
    int is_stderr);
LIBSSH_API int ssh_channel_request_env(ssh_channel channel, const char *name, const char *value);
LIBSSH_API int ssh_channel_request_exec(ssh_channel channel, const char *cmd);
LIBSSH_API int ssh_channel_request_pty(ssh_channel channel);
LIBSSH_API int ssh_channel_request_pty_size(ssh_channel channel, const char *term,
    int cols, int rows);
LIBSSH_API int ssh_channel_request_pty_size_modes(ssh_channel channel, const char *term,
    int cols, int rows, const unsigned char* modes, size_t modes_len);
LIBSSH_API int ssh_channel_request_shell(ssh_channel channel);
LIBSSH_API int ssh_channel_request_send_signal(ssh_channel channel, const char *signum);
LIBSSH_API int ssh_channel_request_send_break(ssh_channel channel, uint32_t length);
LIBSSH_API int ssh_channel_request_sftp(ssh_channel channel);
LIBSSH_API int ssh_channel_request_subsystem(ssh_channel channel, const char *subsystem);
LIBSSH_API int ssh_channel_request_x11(ssh_channel channel, int single_connection, const char *protocol,
    const char *cookie, int screen_number);
LIBSSH_API int ssh_channel_request_auth_agent(ssh_channel channel);
LIBSSH_API int ssh_channel_send_eof(ssh_channel channel);
LIBSSH_API void ssh_channel_set_blocking(ssh_channel channel, int blocking);
LIBSSH_API void ssh_channel_set_counter(ssh_channel channel,
                                        ssh_counter counter);
LIBSSH_API int ssh_channel_write(ssh_channel channel, const void *data, uint32_t len);
LIBSSH_API int ssh_channel_write_stderr(ssh_channel channel,
                                        const void *data,
                                        uint32_t len);
LIBSSH_API uint32_t ssh_channel_window_size(ssh_channel channel);

LIBSSH_API char *ssh_basename (const char *path);
LIBSSH_API void ssh_clean_pubkey_hash(unsigned char **hash);
LIBSSH_API int ssh_connect(ssh_session session);

LIBSSH_API ssh_connector ssh_connector_new(ssh_session session);
LIBSSH_API void ssh_connector_free(ssh_connector connector);
LIBSSH_API int ssh_connector_set_in_channel(ssh_connector connector,
                                            ssh_channel channel,
                                            enum ssh_connector_flags_e flags);
LIBSSH_API int ssh_connector_set_out_channel(ssh_connector connector,
                                             ssh_channel channel,
                                             enum ssh_connector_flags_e flags);
LIBSSH_API void ssh_connector_set_in_fd(ssh_connector connector, socket_t fd);
LIBSSH_API void ssh_connector_set_out_fd(ssh_connector connector, socket_t fd);

LIBSSH_API const char *ssh_copyright(void);
LIBSSH_API void ssh_disconnect(ssh_session session);
LIBSSH_API char *ssh_dirname (const char *path);
LIBSSH_API int ssh_finalize(void);

/* REVERSE PORT FORWARDING */
LIBSSH_API ssh_channel ssh_channel_open_forward_port(ssh_session session,
                                                   int timeout_ms,
                                                   int *destination_port,
                                                   char **originator,
                                                   int *originator_port);
SSH_DEPRECATED LIBSSH_API ssh_channel ssh_channel_accept_forward(ssh_session session,
                                                  int timeout_ms,
                                                  int *destination_port);
LIBSSH_API int ssh_channel_cancel_forward(ssh_session session,
                                          const char *address,
                                          int port);
LIBSSH_API int ssh_channel_listen_forward(ssh_session session,
                                          const char *address,
                                          int port,
                                          int *bound_port);

LIBSSH_API void ssh_free(ssh_session session);
LIBSSH_API const char *ssh_get_disconnect_message(ssh_session session);
LIBSSH_API const char *ssh_get_error(void *error);
LIBSSH_API int ssh_get_error_code(void *error);
LIBSSH_API socket_t ssh_get_fd(ssh_session session);
LIBSSH_API char *ssh_get_hexa(const unsigned char *what, size_t len);
LIBSSH_API char *ssh_get_issue_banner(ssh_session session);
LIBSSH_API int ssh_get_openssh_version(ssh_session session);
LIBSSH_API int ssh_request_no_more_sessions(ssh_session session);

LIBSSH_API int ssh_get_server_publickey(ssh_session session, ssh_key *key);

enum ssh_publickey_hash_type {
    SSH_PUBLICKEY_HASH_SHA1,
    SSH_PUBLICKEY_HASH_MD5,
    SSH_PUBLICKEY_HASH_SHA256
};
LIBSSH_API int ssh_get_publickey_hash(const ssh_key key,
                                      enum ssh_publickey_hash_type type,
                                      unsigned char **hash,
                                      size_t *hlen);

/* DEPRECATED FUNCTIONS */
SSH_DEPRECATED LIBSSH_API int ssh_get_pubkey_hash(ssh_session session, unsigned char **hash);
SSH_DEPRECATED LIBSSH_API ssh_channel ssh_forward_accept(ssh_session session, int timeout_ms);
SSH_DEPRECATED LIBSSH_API int ssh_forward_cancel(ssh_session session, const char *address, int port);
SSH_DEPRECATED LIBSSH_API int ssh_forward_listen(ssh_session session, const char *address, int port, int *bound_port);
SSH_DEPRECATED LIBSSH_API int ssh_get_publickey(ssh_session session, ssh_key *key);
SSH_DEPRECATED LIBSSH_API int ssh_write_knownhost(ssh_session session);
SSH_DEPRECATED LIBSSH_API char *ssh_dump_knownhost(ssh_session session);
SSH_DEPRECATED LIBSSH_API int ssh_is_server_known(ssh_session session);
SSH_DEPRECATED LIBSSH_API void ssh_print_hexa(const char *descr, const unsigned char *what, size_t len);
SSH_DEPRECATED LIBSSH_API int ssh_channel_select(ssh_channel *readchans, ssh_channel *writechans, ssh_channel *exceptchans, struct
        timeval * timeout);

SSH_DEPRECATED LIBSSH_API int ssh_scp_accept_request(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API int ssh_scp_close(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API int ssh_scp_deny_request(ssh_scp scp, const char *reason);
SSH_DEPRECATED LIBSSH_API void ssh_scp_free(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API int ssh_scp_init(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API int ssh_scp_leave_directory(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API ssh_scp ssh_scp_new(ssh_session session, int mode, const char *location);
SSH_DEPRECATED LIBSSH_API int ssh_scp_pull_request(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API int ssh_scp_push_directory(ssh_scp scp, const char *dirname, int mode);
SSH_DEPRECATED LIBSSH_API int ssh_scp_push_file(ssh_scp scp, const char *filename, size_t size, int perms);
SSH_DEPRECATED LIBSSH_API int ssh_scp_push_file64(ssh_scp scp, const char *filename, uint64_t size, int perms);
SSH_DEPRECATED LIBSSH_API int ssh_scp_read(ssh_scp scp, void *buffer, size_t size);
SSH_DEPRECATED LIBSSH_API const char *ssh_scp_request_get_filename(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API int ssh_scp_request_get_permissions(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API size_t ssh_scp_request_get_size(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API uint64_t ssh_scp_request_get_size64(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API const char *ssh_scp_request_get_warning(ssh_scp scp);
SSH_DEPRECATED LIBSSH_API int ssh_scp_write(ssh_scp scp, const void *buffer, size_t len);


LIBSSH_API int ssh_get_random(void *where,int len,int strong);
LIBSSH_API int ssh_get_version(ssh_session session);
LIBSSH_API int ssh_get_status(ssh_session session);
LIBSSH_API int ssh_get_poll_flags(ssh_session session);
LIBSSH_API int ssh_init(void);
LIBSSH_API int ssh_is_blocking(ssh_session session);
LIBSSH_API int ssh_is_connected(ssh_session session);

/* KNOWN HOSTS */
LIBSSH_API void ssh_knownhosts_entry_free(struct ssh_knownhosts_entry *entry);
#define SSH_KNOWNHOSTS_ENTRY_FREE(e) do { \
  if ((e) != NULL) { \
    ssh_knownhosts_entry_free(e); \
    e = NULL; \
  } \
} while(0)

LIBSSH_API int ssh_known_hosts_parse_line(const char *host,
                                          const char *line,
                                          struct ssh_knownhosts_entry **entry);
LIBSSH_API enum ssh_known_hosts_e ssh_session_has_known_hosts_entry(ssh_session session);

LIBSSH_API int ssh_session_export_known_hosts_entry(ssh_session session,
                                                    char **pentry_string);
LIBSSH_API int ssh_session_update_known_hosts(ssh_session session);

LIBSSH_API enum ssh_known_hosts_e ssh_session_get_known_hosts_entry(ssh_session session,
        struct ssh_knownhosts_entry **pentry);
LIBSSH_API enum ssh_known_hosts_e ssh_session_is_known_server(ssh_session session);

/* LOGGING */
LIBSSH_API int ssh_set_log_level(int level);
LIBSSH_API int ssh_get_log_level(void);
LIBSSH_API void *ssh_get_log_userdata(void);
LIBSSH_API int ssh_set_log_userdata(void *data);
LIBSSH_API void ssh_vlog(int verbosity,
                         const char *function,
                         const char *format,
                         va_list *va) PRINTF_ATTRIBUTE(3, 0);
LIBSSH_API void _ssh_log(int verbosity,
                         const char *function,
                         const char *format, ...) PRINTF_ATTRIBUTE(3, 4);

/* legacy */
SSH_DEPRECATED LIBSSH_API void ssh_log(ssh_session session,
                                       int prioriry,
                                       const char *format, ...) PRINTF_ATTRIBUTE(3, 4);

LIBSSH_API ssh_channel ssh_message_channel_request_open_reply_accept(ssh_message msg);
LIBSSH_API int ssh_message_channel_request_open_reply_accept_channel(ssh_message msg, ssh_channel chan);
LIBSSH_API int ssh_message_channel_request_reply_success(ssh_message msg);
#define SSH_MESSAGE_FREE(x) \
    do { if ((x) != NULL) { ssh_message_free(x); (x) = NULL; } } while(0)
LIBSSH_API void ssh_message_free(ssh_message msg);
LIBSSH_API ssh_message ssh_message_get(ssh_session session);
LIBSSH_API int ssh_message_subtype(ssh_message msg);
LIBSSH_API int ssh_message_type(ssh_message msg);
LIBSSH_API int ssh_mkdir (const char *pathname, mode_t mode);
LIBSSH_API ssh_session ssh_new(void);

LIBSSH_API int ssh_options_copy(ssh_session src, ssh_session *dest);
LIBSSH_API int ssh_options_getopt(ssh_session session, int *argcptr, char **argv);
LIBSSH_API int ssh_options_parse_config(ssh_session session, const char *filename);
LIBSSH_API int ssh_options_set(ssh_session session, enum ssh_options_e type,
    const void *value);
LIBSSH_API int ssh_options_get(ssh_session session, enum ssh_options_e type,
    char **value);
LIBSSH_API int ssh_options_get_port(ssh_session session, unsigned int * port_target);
LIBSSH_API int ssh_pcap_file_close(ssh_pcap_file pcap);
LIBSSH_API void ssh_pcap_file_free(ssh_pcap_file pcap);
LIBSSH_API ssh_pcap_file ssh_pcap_file_new(void);
LIBSSH_API int ssh_pcap_file_open(ssh_pcap_file pcap, const char *filename);

/**
 * @addtogroup libssh_auth
 *
 * @{
 */

/**
 * @brief SSH authentication callback for password and publickey auth.
 *
 * @param prompt        Prompt to be displayed.
 * @param buf           Buffer to save the password. You should null-terminate it.
 * @param len           Length of the buffer.
 * @param echo          Enable or disable the echo of what you type.
 * @param verify        Should the password be verified?
 * @param userdata      Userdata to be passed to the callback function. Useful
 *                      for GUI applications.
 *
 * @return              0 on success, < 0 on error.
 */
typedef int (*ssh_auth_callback) (const char *prompt, char *buf, size_t len,
    int echo, int verify, void *userdata);

/** @} */

enum ssh_file_format_e {
    SSH_FILE_FORMAT_DEFAULT = 0,
    SSH_FILE_FORMAT_OPENSSH,
    SSH_FILE_FORMAT_PEM,
};

LIBSSH_API ssh_key ssh_key_new(void);
#define SSH_KEY_FREE(x) \
    do { if ((x) != NULL) { ssh_key_free(x); x = NULL; } } while(0)
LIBSSH_API void ssh_key_free (ssh_key key);
LIBSSH_API enum ssh_keytypes_e ssh_key_type(const ssh_key key);
LIBSSH_API const char *ssh_key_type_to_char(enum ssh_keytypes_e type);
LIBSSH_API enum ssh_keytypes_e ssh_key_type_from_name(const char *name);
LIBSSH_API int ssh_key_is_public(const ssh_key k);
LIBSSH_API int ssh_key_is_private(const ssh_key k);
LIBSSH_API int ssh_key_cmp(const ssh_key k1,
                           const ssh_key k2,
                           enum ssh_keycmp_e what);
LIBSSH_API ssh_key ssh_key_dup(const ssh_key key);
LIBSSH_API uint32_t ssh_key_get_sk_flags(const ssh_key key);
LIBSSH_API ssh_string ssh_key_get_sk_application(const ssh_key key);
LIBSSH_API ssh_string ssh_key_get_sk_user_id(const ssh_key key);

SSH_DEPRECATED LIBSSH_API int
ssh_pki_generate(enum ssh_keytypes_e type, int parameter, ssh_key *pkey);

LIBSSH_API int ssh_pki_generate_key(enum ssh_keytypes_e type,
                                    ssh_pki_ctx pki_context,
                                    ssh_key *pkey);

LIBSSH_API int ssh_pki_import_privkey_base64(const char *b64_key,
                                             const char *passphrase,
                                             ssh_auth_callback auth_fn,
                                             void *auth_data,
                                             ssh_key *pkey);
LIBSSH_API int ssh_pki_export_privkey_base64(const ssh_key privkey,
                                             const char *passphrase,
                                             ssh_auth_callback auth_fn,
                                             void *auth_data,
                                             char **b64_key);
LIBSSH_API int
ssh_pki_export_privkey_base64_format(const ssh_key privkey,
                                     const char *passphrase,
                                     ssh_auth_callback auth_fn,
                                     void *auth_data,
                                     char **b64_key,
                                     enum ssh_file_format_e format);
LIBSSH_API int ssh_pki_import_privkey_file(const char *filename,
                                           const char *passphrase,
                                           ssh_auth_callback auth_fn,
                                           void *auth_data,
                                           ssh_key *pkey);
LIBSSH_API int ssh_pki_export_privkey_file(const ssh_key privkey,
                                           const char *passphrase,
                                           ssh_auth_callback auth_fn,
                                           void *auth_data,
                                           const char *filename);
LIBSSH_API int
ssh_pki_export_privkey_file_format(const ssh_key privkey,
                                   const char *passphrase,
                                   ssh_auth_callback auth_fn,
                                   void *auth_data,
                                   const char *filename,
                                   enum ssh_file_format_e format);

LIBSSH_API int ssh_pki_copy_cert_to_privkey(const ssh_key cert_key,
                                            ssh_key privkey);

LIBSSH_API int ssh_pki_import_pubkey_base64(const char *b64_key,
                                            enum ssh_keytypes_e type,
                                            ssh_key *pkey);
LIBSSH_API int ssh_pki_import_pubkey_file(const char *filename,
                                          ssh_key *pkey);

LIBSSH_API int ssh_pki_import_cert_base64(const char *b64_cert,
                                          enum ssh_keytypes_e type,
                                          ssh_key *pkey);
LIBSSH_API int ssh_pki_import_cert_file(const char *filename,
                                        ssh_key *pkey);

LIBSSH_API int ssh_pki_export_privkey_to_pubkey(const ssh_key privkey,
                                                ssh_key *pkey);
LIBSSH_API int ssh_pki_export_pubkey_base64(const ssh_key key,
                                            char **b64_key);
LIBSSH_API int ssh_pki_export_pubkey_file(const ssh_key key,
                                          const char *filename);

LIBSSH_API const char *ssh_pki_key_ecdsa_name(const ssh_key key);

LIBSSH_API char *ssh_get_fingerprint_hash(enum ssh_publickey_hash_type type,
                                          unsigned char *hash,
                                          size_t len);
LIBSSH_API void ssh_print_hash(enum ssh_publickey_hash_type type, unsigned char *hash, size_t len);
LIBSSH_API int ssh_send_ignore (ssh_session session, const char *data);
LIBSSH_API int ssh_send_debug (ssh_session session, const char *message, int always_display);
LIBSSH_API void ssh_gssapi_set_creds(ssh_session session, const ssh_gssapi_creds creds);
LIBSSH_API int ssh_select(ssh_channel *channels, ssh_channel *outchannels, socket_t maxfd,
    fd_set *readfds, struct timeval *timeout);
LIBSSH_API int ssh_service_request(ssh_session session, const char *service);
LIBSSH_API int ssh_set_agent_channel(ssh_session session, ssh_channel channel);
LIBSSH_API int ssh_set_agent_socket(ssh_session session, socket_t fd);
LIBSSH_API void ssh_set_blocking(ssh_session session, int blocking);
LIBSSH_API void ssh_set_counters(ssh_session session, ssh_counter scounter,
                                 ssh_counter rcounter);
LIBSSH_API void ssh_set_fd_except(ssh_session session);
LIBSSH_API void ssh_set_fd_toread(ssh_session session);
LIBSSH_API void ssh_set_fd_towrite(ssh_session session);
LIBSSH_API void ssh_silent_disconnect(ssh_session session);
LIBSSH_API int ssh_set_pcap_file(ssh_session session, ssh_pcap_file pcapfile);

/* USERAUTH */
LIBSSH_API int ssh_userauth_none(ssh_session session, const char *username);
LIBSSH_API int ssh_userauth_list(ssh_session session, const char *username);
LIBSSH_API int ssh_userauth_try_publickey(ssh_session session,
                                          const char *username,
                                          const ssh_key pubkey);
LIBSSH_API int ssh_userauth_publickey(ssh_session session,
                                      const char *username,
                                      const ssh_key privkey);
LIBSSH_API int ssh_userauth_agent(ssh_session session,
                                  const char *username);
LIBSSH_API int ssh_userauth_publickey_auto_get_current_identity(ssh_session session,
                                                                char** value);
LIBSSH_API int ssh_userauth_publickey_auto(ssh_session session,
                                           const char *username,
                                           const char *passphrase);
LIBSSH_API int ssh_userauth_password(ssh_session session,
                                     const char *username,
                                     const char *password);

LIBSSH_API int ssh_userauth_kbdint(ssh_session session, const char *user, const char *submethods);
LIBSSH_API const char *ssh_userauth_kbdint_getinstruction(ssh_session session);
LIBSSH_API const char *ssh_userauth_kbdint_getname(ssh_session session);
LIBSSH_API int ssh_userauth_kbdint_getnprompts(ssh_session session);
LIBSSH_API const char *ssh_userauth_kbdint_getprompt(ssh_session session, unsigned int i, char *echo);
LIBSSH_API int ssh_userauth_kbdint_getnanswers(ssh_session session);
LIBSSH_API const char *ssh_userauth_kbdint_getanswer(ssh_session session, unsigned int i);
LIBSSH_API int ssh_userauth_kbdint_setanswer(ssh_session session, unsigned int i,
    const char *answer);
LIBSSH_API int ssh_userauth_gssapi(ssh_session session);
LIBSSH_API int ssh_userauth_gssapi_keyex(ssh_session session);
LIBSSH_API const char *ssh_version(int req_version);

LIBSSH_API void ssh_string_burn(ssh_string str);
LIBSSH_API ssh_string ssh_string_copy(ssh_string str);
LIBSSH_API void *ssh_string_data(ssh_string str);
LIBSSH_API int ssh_string_fill(ssh_string str, const void *data, size_t len);
#define SSH_STRING_FREE(x) \
    do { if ((x) != NULL) { ssh_string_free(x); x = NULL; } } while(0)
LIBSSH_API void ssh_string_free(ssh_string str);
LIBSSH_API ssh_string ssh_string_from_char(const char *what);
LIBSSH_API ssh_string ssh_string_from_data(const void *data, size_t len);
LIBSSH_API size_t ssh_string_len(ssh_string str);
LIBSSH_API ssh_string ssh_string_new(size_t size);
LIBSSH_API const char *ssh_string_get_char(ssh_string str);
LIBSSH_API char *ssh_string_to_char(ssh_string str);
#define SSH_STRING_FREE_CHAR(x) \
    do { if ((x) != NULL) { ssh_string_free_char(x); x = NULL; } } while(0)
LIBSSH_API void ssh_string_free_char(char *s);
LIBSSH_API int ssh_string_cmp(ssh_string s1, ssh_string s2);

LIBSSH_API int ssh_getpass(const char *prompt, char *buf, size_t len, int echo,
    int verify);


typedef int (*ssh_event_callback)(socket_t fd, int revents, void *userdata);

LIBSSH_API ssh_event ssh_event_new(void);
LIBSSH_API int ssh_event_add_fd(ssh_event event, socket_t fd, short events,
                                    ssh_event_callback cb, void *userdata);
LIBSSH_API int ssh_event_add_session(ssh_event event, ssh_session session);
LIBSSH_API int ssh_event_add_connector(ssh_event event, ssh_connector connector);
LIBSSH_API int ssh_event_dopoll(ssh_event event, int timeout);
LIBSSH_API int ssh_event_remove_fd(ssh_event event, socket_t fd);
LIBSSH_API int ssh_event_remove_session(ssh_event event, ssh_session session);
LIBSSH_API int ssh_event_remove_connector(ssh_event event, ssh_connector connector);
LIBSSH_API void ssh_event_free(ssh_event event);
LIBSSH_API const char* ssh_get_clientbanner(ssh_session session);
LIBSSH_API const char* ssh_get_serverbanner(ssh_session session);
LIBSSH_API const char* ssh_get_kex_algo(ssh_session session);
LIBSSH_API bool ssh_session_kex_is_gss(ssh_session session);
LIBSSH_API const char* ssh_get_cipher_in(ssh_session session);
LIBSSH_API const char* ssh_get_cipher_out(ssh_session session);
LIBSSH_API const char* ssh_get_hmac_in(ssh_session session);
LIBSSH_API const char* ssh_get_hmac_out(ssh_session session);
LIBSSH_API const char *ssh_get_supported_methods(enum ssh_kex_types_e type);

LIBSSH_API ssh_buffer ssh_buffer_new(void);
LIBSSH_API void ssh_buffer_free(ssh_buffer buffer);
#define SSH_BUFFER_FREE(x) \
    do { if ((x) != NULL) { ssh_buffer_free(x); x = NULL; } } while(0)
LIBSSH_API int ssh_buffer_reinit(ssh_buffer buffer);
LIBSSH_API int ssh_buffer_add_data(ssh_buffer buffer, const void *data, uint32_t len);
LIBSSH_API uint32_t ssh_buffer_get_data(ssh_buffer buffer, void *data, uint32_t requestedlen);
LIBSSH_API void *ssh_buffer_get(ssh_buffer buffer);
LIBSSH_API uint32_t ssh_buffer_get_len(ssh_buffer buffer);
LIBSSH_API int ssh_session_set_disconnect_message(ssh_session session, const char *message);

/* SSHSIG hashes data independently from the key used, so we use a new enum
   to avoid confusion. See
   https://gitlab.com/jas/ietf-sshsig-format/-/blob/cc70a225cbd695d5a6f20aaebdb4b92b0818e43a/ietf-sshsig-format.md#L137
 */
enum sshsig_digest_e {
    SSHSIG_DIGEST_SHA2_256 = 0,
    SSHSIG_DIGEST_SHA2_512 = 1,
};

LIBSSH_API int sshsig_sign(const void *data,
                           size_t data_length,
                           ssh_key privkey,
                           ssh_pki_ctx pki_context,
                           const char *sig_namespace,
                           enum sshsig_digest_e hash_alg,
                           char **signature);
LIBSSH_API int sshsig_verify(const void *data,
                             size_t data_length,
                             const char *signature,
                             const char *sig_namespace,
                             ssh_key *sign_key);

/* PKI context API */

enum ssh_pki_options_e {
    SSH_PKI_OPTION_RSA_KEY_SIZE,

    /* Security Key options */
    SSH_PKI_OPTION_SK_APPLICATION,
    SSH_PKI_OPTION_SK_FLAGS,
    SSH_PKI_OPTION_SK_USER_ID,
    SSH_PKI_OPTION_SK_CHALLENGE,
    SSH_PKI_OPTION_SK_CALLBACKS,
};

/* FIDO2/U2F Operation Flags */

/** Requires user presence confirmation (tap/touch) */
#ifndef SSH_SK_USER_PRESENCE_REQD
#define SSH_SK_USER_PRESENCE_REQD 0x01
#endif

/** Requires user verification (PIN/biometric) - FIDO2 only */
#ifndef SSH_SK_USER_VERIFICATION_REQD
#define SSH_SK_USER_VERIFICATION_REQD 0x04
#endif

/** Force resident key enrollment even if a resident key with given user ID
 * already exists - FIDO2 only */
#ifndef SSH_SK_FORCE_OPERATION
#define SSH_SK_FORCE_OPERATION 0x10
#endif

/** Create/use resident key stored on authenticator - FIDO2 only */
#ifndef SSH_SK_RESIDENT_KEY
#define SSH_SK_RESIDENT_KEY 0x20
#endif

LIBSSH_API ssh_pki_ctx ssh_pki_ctx_new(void);

LIBSSH_API int ssh_pki_ctx_options_set(ssh_pki_ctx context,
                                       enum ssh_pki_options_e option,
                                       const void *value);

LIBSSH_API int ssh_pki_ctx_set_sk_pin_callback(ssh_pki_ctx context,
                                               ssh_auth_callback pin_callback,
                                               void *userdata);

#define SSH_SK_OPTION_NAME_DEVICE_PATH "device"
#define SSH_SK_OPTION_NAME_USER_ID     "user"

LIBSSH_API int ssh_pki_ctx_sk_callbacks_option_set(ssh_pki_ctx context,
                                                   const char *name,
                                                   const char *value,
                                                   bool required);

LIBSSH_API int ssh_pki_ctx_sk_callbacks_options_clear(ssh_pki_ctx context);

LIBSSH_API int
ssh_pki_ctx_get_sk_attestation_buffer(const struct ssh_pki_ctx_struct *context,
                                      ssh_buffer *attestation_buffer);

LIBSSH_API void ssh_pki_ctx_free(ssh_pki_ctx context);

#define SSH_PKI_CTX_FREE(x)      \
    do {                         \
        if ((x) != NULL) {       \
            ssh_pki_ctx_free(x); \
            x = NULL;            \
        }                        \
    } while (0)

/* Security key resident keys API */

LIBSSH_API int
ssh_sk_resident_keys_load(const struct ssh_pki_ctx_struct *pki_context,
                          ssh_key **resident_keys_result,
                          size_t *num_keys_found_result);

#ifndef LIBSSH_LEGACY_0_4
#include "libssh/legacy.h"
#endif

#ifdef __cplusplus
}
#endif
#endif /* _LIBSSH_H */
