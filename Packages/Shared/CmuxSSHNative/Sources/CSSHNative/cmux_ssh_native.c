#include "cmux_ssh_native.h"
#include <libssh/libssh.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <poll.h>

struct cmux_ssh { ssh_session session; ssh_channel channel; ssh_key key; };
void cmux_ssh_destroy(cmux_ssh *s);
static int result(int code) {
    return code==SSH_OK?CMUX_SSH_OK:(code==SSH_AGAIN?CMUX_SSH_AGAIN:CMUX_SSH_ERROR);
}
static int auth_result(int code) {
    switch(code) {
        case SSH_AUTH_SUCCESS: return CMUX_SSH_OK;
        case SSH_AUTH_AGAIN: return CMUX_SSH_AGAIN;
        case SSH_AUTH_INFO: return CMUX_SSH_CHALLENGE;
        case SSH_AUTH_DENIED: return CMUX_SSH_DENIED;
        case SSH_AUTH_PARTIAL: return CMUX_SSH_PARTIAL;
        default: return CMUX_SSH_ERROR;
    }
}
cmux_ssh *cmux_ssh_create(const char *host, int port, const char *user) {
    cmux_ssh *s=calloc(1,sizeof(*s)); if(!s)return NULL;
    s->session=ssh_new(); if(!s->session) {free(s);return NULL;}
    int disabled=0; long timeout=30;
    /* Never import the process user's config, agent, identities, or known_hosts. */
    if(ssh_options_set(s->session,SSH_OPTIONS_PROCESS_CONFIG,&disabled)!=SSH_OK ||
       ssh_options_set(s->session,SSH_OPTIONS_HOST,host)!=SSH_OK ||
       ssh_options_set(s->session,SSH_OPTIONS_PORT,&port)!=SSH_OK ||
       ssh_options_set(s->session,SSH_OPTIONS_USER,user)!=SSH_OK ||
       ssh_options_set(s->session,SSH_OPTIONS_TIMEOUT,&timeout)!=SSH_OK) {
        cmux_ssh_destroy(s);return NULL;
    }
    ssh_set_blocking(s->session,0);
    return s;
}
void cmux_ssh_destroy(cmux_ssh *s) {
    if(!s)return;
    /* Teardown never waits for peer acknowledgement. */
    if(s->session) {
        int fd=ssh_get_fd(s->session);
        if(fd>=0)(void)shutdown(fd,SHUT_RDWR);
    }
    if(s->channel)ssh_channel_free(s->channel);
    if(s->key)ssh_key_free(s->key);
    if(s->session) {ssh_disconnect(s->session);ssh_free(s->session);}
    free(s);
}
int cmux_ssh_connect(cmux_ssh *s) {return result(ssh_connect(s->session));}
int cmux_ssh_wait(cmux_ssh *s,int timeout_ms) {
    int fd=ssh_get_fd(s->session); if(fd<0)return CMUX_SSH_ERROR;
    struct pollfd descriptor={.fd=fd,.events=(short)(cmux_ssh_wants_write(s)?POLLOUT:POLLIN)};
    int rc=poll(&descriptor,1,timeout_ms); return rc<0?CMUX_SSH_ERROR:(rc==0?CMUX_SSH_AGAIN:CMUX_SSH_OK);
}
int cmux_ssh_fd(cmux_ssh *s) {return ssh_get_fd(s->session);}
int cmux_ssh_wants_write(cmux_ssh *s) {return (ssh_get_poll_flags(s->session)&SSH_WRITE_PENDING)!=0;}
int cmux_ssh_host_key(cmux_ssh *s,char *algorithm,size_t an,char *fingerprint,size_t fn) {
    ssh_key key=NULL; unsigned char *hash=NULL; size_t length=0;
    if(ssh_get_server_publickey(s->session,&key)!=SSH_OK)return CMUX_SSH_ERROR;
    const char *name=ssh_key_type_to_char(ssh_key_type(key));
    int rc=CMUX_SSH_ERROR;
    if(name && strlen(name)<an &&
       ssh_get_publickey_hash(key,SSH_PUBLICKEY_HASH_SHA256,&hash,&length)==SSH_OK) {
        char *fp=ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256,hash,length);
        if(fp && strlen(fp)<fn) {strcpy(algorithm,name);strcpy(fingerprint,fp);rc=CMUX_SSH_OK;}
        ssh_string_free_char(fp);
    }
    ssh_clean_pubkey_hash(&hash);ssh_key_free(key);return rc;
}
int cmux_ssh_auth_password(cmux_ssh *s,const char *password) {
    return auth_result(ssh_userauth_password(s->session,NULL,password));
}
int cmux_ssh_load_private_key(cmux_ssh *s,const char *key,const char *passphrase) {
    if(s->key) {ssh_key_free(s->key);s->key=NULL;}
    /* No file or interactive callback fallback. */
    return result(ssh_pki_import_privkey_base64(key,passphrase,NULL,NULL,&s->key));
}
int cmux_ssh_auth_key(cmux_ssh *s) {
    return s->key?auth_result(ssh_userauth_publickey(s->session,NULL,s->key)):CMUX_SSH_ERROR;
}
int cmux_ssh_auth_none(cmux_ssh *s) {return auth_result(ssh_userauth_none(s->session,NULL));}
int cmux_ssh_auth_keyboard(cmux_ssh *s) {return auth_result(ssh_userauth_kbdint(s->session,NULL,NULL));}
int cmux_ssh_prompt_count(cmux_ssh *s) {return ssh_userauth_kbdint_getnprompts(s->session);}
const char *cmux_ssh_prompt(cmux_ssh *s,unsigned index,int *echo) {
    char value=0;const char *text=ssh_userauth_kbdint_getprompt(s->session,index,&value);
    *echo=value!=0;return text;
}
const char *cmux_ssh_prompt_name(cmux_ssh *s) {return ssh_userauth_kbdint_getname(s->session);}
const char *cmux_ssh_prompt_instruction(cmux_ssh *s) {return ssh_userauth_kbdint_getinstruction(s->session);}
int cmux_ssh_prompt_answer(cmux_ssh *s,unsigned index,const char *answer) {
    return result(ssh_userauth_kbdint_setanswer(s->session,index,answer));
}
int cmux_ssh_open_channel(cmux_ssh *s) {
    if(!s->channel)s->channel=ssh_channel_new(s->session);
    return s->channel?result(ssh_channel_open_session(s->channel)):CMUX_SSH_ERROR;
}
int cmux_ssh_environment(cmux_ssh *s,const char *name,const char *value) {
    return result(ssh_channel_request_env(s->channel,name,value));
}
int cmux_ssh_request_pty(cmux_ssh *s,int columns,int rows) {
    return result(ssh_channel_request_pty_size(s->channel,"xterm-256color",columns,rows));
}
int cmux_ssh_request_shell(cmux_ssh *s) {return result(ssh_channel_request_shell(s->channel));}
int cmux_ssh_request_exec(cmux_ssh *s,const char *command) {return result(ssh_channel_request_exec(s->channel,command));}
int cmux_ssh_resize(cmux_ssh *s,int columns,int rows) {return result(ssh_channel_change_pty_size(s->channel,columns,rows));}
int cmux_ssh_read_timeout(cmux_ssh *s,void *buffer,uint32_t capacity,int stderr_stream,int timeout_ms) {
    int rc=ssh_channel_read_timeout(s->channel,buffer,capacity,stderr_stream,timeout_ms);
    return rc==SSH_AGAIN?0:rc;
}
int cmux_ssh_write(cmux_ssh *s,const void *buffer,uint32_t count) {
    int rc=ssh_channel_write(s->channel,buffer,count);return rc==SSH_AGAIN?0:rc;
}
int cmux_ssh_eof(cmux_ssh *s) {return ssh_channel_is_eof(s->channel);}
int cmux_ssh_closed(cmux_ssh *s) {return ssh_channel_is_closed(s->channel);}
